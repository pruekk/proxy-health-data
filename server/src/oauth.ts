// Minimal OAuth 2.1 authorization server, so Claude connectors (claude.ai web + mobile apps) can sign in.
// Static API_TOKENS keep working for the iOS app and `claude mcp add --header`; this adds the browser flow:
//   discovery -> dynamic client registration -> /oauth/authorize (paste an API token) -> code + PKCE -> /oauth/token
// Specs: RFC 9728 (protected-resource metadata), RFC 8414 (AS metadata), RFC 7591 (DCR), RFC 7636 (PKCE).

import { Timestamp } from 'firebase-admin/firestore'
import { Elysia } from 'elysia'
import { createHash, randomBytes } from 'node:crypto'
import { env, resolveStaticToken } from './env'
import { db } from './firebase'

const SCOPE = 'health.read'
const CODE_TTL_MS = 10 * 60_000
const ACCESS_TTL_S = 30 * 24 * 3600
const REFRESH_TTL_S = 180 * 24 * 3600

// Firestore: oauthClients/{clientId}, oauthCodes/{sha256(code)}, oauthTokens/{sha256(token)}.
// Codes and tokens are stored hashed, so a leaked database dump grants nothing.
const clients = db.collection('oauthClients')
const codes = db.collection('oauthCodes')
const tokens = db.collection('oauthTokens')

const hash = (value: string) => createHash('sha256').update(value).digest('hex')
const challengeOf = (verifier: string) => createHash('sha256').update(verifier).digest('base64url')
const secret = () => randomBytes(32).toString('base64url')
const isExpired = (at: unknown) => !(at instanceof Timestamp) || at.toMillis() < Date.now()
const str = (v: unknown) => (typeof v === 'string' ? v.trim() : '')

// The issuer must match the host the client actually used — this service answers on more than one
// Cloud Run hostname. PUBLIC_URL pins it if you put the API behind a custom domain.
export function baseUrl(headers: Record<string, string | undefined>): string {
  if (env.publicUrl) return env.publicUrl.replace(/\/+$/, '')
  const host = (headers['x-forwarded-host'] ?? headers.host ?? `localhost:${env.port}`).split(',')[0]!.trim()
  const fallback = /^(localhost|127\.|\[::1\])/.test(host) ? 'http' : 'https'
  const proto = (headers['x-forwarded-proto'] ?? fallback).split(',')[0]!.trim()
  return `${proto}://${host}`
}

export const resourceMetadata = (base: string) => ({
  resource: `${base}/mcp`,
  authorization_servers: [base],
  scopes_supported: [SCOPE],
  bearer_methods_supported: ['header'],
})

const serverMetadata = (base: string) => ({
  issuer: base,
  authorization_endpoint: `${base}/oauth/authorize`,
  token_endpoint: `${base}/oauth/token`,
  registration_endpoint: `${base}/oauth/register`,
  revocation_endpoint: `${base}/oauth/revoke`,
  scopes_supported: [SCOPE],
  response_types_supported: ['code'],
  response_modes_supported: ['query'],
  grant_types_supported: ['authorization_code', 'refresh_token'],
  token_endpoint_auth_methods_supported: ['none'],
  code_challenge_methods_supported: ['S256'],
})

// ---------- access tokens ----------

// Returns the uid an issued bearer token belongs to, or null. Called on every authenticated request.
export async function resolveAccessToken(token: string): Promise<string | null> {
  if (!token) return null
  const doc = await tokens.doc(hash(token)).get()
  if (!doc.exists || doc.get('kind') !== 'access' || isExpired(doc.get('expiresAt'))) return null
  return str(doc.get('uid')) || null
}

async function issueTokens(uid: string, clientId: string) {
  const access = secret()
  const refresh = secret()
  const now = Date.now()
  const common = { uid, clientId, createdAt: Timestamp.now() }
  await Promise.all([
    tokens.doc(hash(access)).set({ ...common, kind: 'access', expiresAt: Timestamp.fromMillis(now + ACCESS_TTL_S * 1000) }),
    tokens.doc(hash(refresh)).set({ ...common, kind: 'refresh', expiresAt: Timestamp.fromMillis(now + REFRESH_TTL_S * 1000) }),
  ])
  return { access_token: access, token_type: 'Bearer', expires_in: ACCESS_TTL_S, refresh_token: refresh, scope: SCOPE }
}

// Drops every OAuth token a user holds — the "sign this person out everywhere" switch.
export async function revokeUserTokens(uid: string): Promise<number> {
  const snap = await tokens.where('uid', '==', uid).get()
  await Promise.all(snap.docs.map((d) => d.ref.delete()))
  return snap.size
}

// ---------- authorize ----------

interface Authz {
  clientId: string
  redirectUri: string
  state: string
  challenge: string
  scope: string
  resource: string
}

// Reads the request's authorize parameters, after checking client_id/redirect_uri against the
// registration. `redirect` tells the caller whether errors may be sent back to the client.
async function readAuthz(q: Record<string, unknown>): Promise<{ error: string; redirect: boolean } | Authz> {
  const clientId = str(q.client_id)
  const redirectUri = str(q.redirect_uri)
  if (!clientId || !redirectUri) return { error: 'client_id and redirect_uri are required.', redirect: false }

  const client = await clients.doc(clientId).get()
  if (!client.exists) return { error: 'Unknown client — remove the connector and add it again.', redirect: false }
  const registered: unknown = client.get('redirectUris')
  if (!Array.isArray(registered) || !registered.includes(redirectUri)) {
    return { error: 'redirect_uri does not match this client registration.', redirect: false }
  }

  if (str(q.response_type) !== 'code') return { error: 'unsupported_response_type', redirect: true }
  const challenge = str(q.code_challenge)
  if (!challenge || str(q.code_challenge_method) !== 'S256') return { error: 'invalid_request', redirect: true }

  return { clientId, redirectUri, state: str(q.state), challenge, scope: str(q.scope) || SCOPE, resource: str(q.resource) }
}

const esc = (value: string) =>
  value.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!)

const html = (body: string, status = 200) =>
  new Response(
    `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Proxy Health Data</title><style>
:root{color-scheme:dark light}
body{margin:0;min-height:100vh;display:grid;place-items:center;background:#111;color:#eee;
font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
main{width:min(26rem,calc(100vw - 2.5rem));padding:2rem;background:#1b1b1b;border-radius:14px}
h1{margin:0 0 .25rem;font-size:1.15rem}p{margin:0 0 1.25rem;color:#aaa;font-size:.9rem}
label{display:block;margin-bottom:.4rem;font-size:.85rem;color:#ccc}
input{width:100%;box-sizing:border-box;padding:.7rem;border-radius:8px;border:1px solid #3a3a3a;
background:#141414;color:#eee;font-family:ui-monospace,SFMono-Regular,monospace}
button{margin-top:1rem;width:100%;padding:.7rem;border:0;border-radius:8px;background:#d97757;color:#1a1a1a;
font-size:1rem;font-weight:600;cursor:pointer}
.err{margin:0 0 1rem;padding:.65rem .8rem;border-radius:8px;background:#3a1f1c;color:#f3b9ab;font-size:.85rem}
</style></head><body><main>${body}</main></body></html>`,
    { status, headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' } },
  )

const signInPage = (p: Authz, error?: string) => {
  const fields: Record<string, string> = {
    response_type: 'code',
    client_id: p.clientId,
    redirect_uri: p.redirectUri,
    state: p.state,
    code_challenge: p.challenge,
    code_challenge_method: 'S256',
    scope: p.scope,
    resource: p.resource,
  }
  const hidden = Object.entries(fields)
    .map(([name, value]) => `<input type="hidden" name="${name}" value="${esc(value)}">`)
    .join('')
  return html(`<h1>Connect to Proxy Health Data</h1>
<p>Paste an API token to give this client read-only access to your Apple Health data.</p>
${error ? `<div class="err">${esc(error)}</div>` : ''}
<form method="post" action="/oauth/authorize">${hidden}
<label for="token">API token</label>
<input id="token" name="token" type="password" autocomplete="off" autocapitalize="none" spellcheck="false" autofocus required>
<button type="submit">Allow access</button></form>`)
}

const errorPage = (message: string, status = 400) => html(`<h1>Can't connect</h1><p>${esc(message)}</p>`, status)

const redirectTo = (url: string) => new Response('', { status: 302, headers: { location: url, 'cache-control': 'no-store' } })

function redirectError(p: { redirectUri: string; state: string }, code: string) {
  const url = new URL(p.redirectUri)
  url.searchParams.set('error', code)
  if (p.state) url.searchParams.set('state', p.state)
  return redirectTo(url.toString())
}

// ---------- routes ----------

// Raw Response bodies bypass the app-level onAfterHandle, so CORS is set here too.
const jsonHeaders = { 'content-type': 'application/json', 'cache-control': 'no-store', 'access-control-allow-origin': '*' } as const
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: jsonHeaders })

const oauthError = (error: string, description: string, status = 400) => json({ error, error_description: description }, status)

export const oauth = new Elysia({ name: 'oauth' })
  // Discovery. Clients try the path-suffixed form first (RFC 9728 / RFC 8414 §3.1), then the plain one.
  .get('/.well-known/oauth-protected-resource', ({ headers }) => json(resourceMetadata(baseUrl(headers))))
  .get('/.well-known/oauth-protected-resource/mcp', ({ headers }) => json(resourceMetadata(baseUrl(headers))))
  .get('/.well-known/oauth-authorization-server', ({ headers }) => json(serverMetadata(baseUrl(headers))))
  .get('/.well-known/oauth-authorization-server/mcp', ({ headers }) => json(serverMetadata(baseUrl(headers))))

  // Dynamic client registration: open, but a client id alone grants nothing — the user still has to
  // paste a valid API token on the authorize page.
  .post('/oauth/register', async ({ body }) => {
    const b = (body ?? {}) as Record<string, unknown>
    const redirectUris = Array.isArray(b.redirect_uris) ? b.redirect_uris.map(String).filter(Boolean) : []
    if (!redirectUris.length) return oauthError('invalid_redirect_uri', 'redirect_uris is required')
    if (redirectUris.some((uri) => !URL.canParse(uri))) return oauthError('invalid_redirect_uri', 'redirect_uris must be absolute URIs')

    const clientId = randomBytes(16).toString('hex')
    const clientName = str(b.client_name) || 'MCP client'
    await clients.doc(clientId).set({ clientName, redirectUris, createdAt: Timestamp.now() })
    return json(
      {
        client_id: clientId,
        client_id_issued_at: Math.floor(Date.now() / 1000),
        client_name: clientName,
        redirect_uris: redirectUris,
        grant_types: ['authorization_code', 'refresh_token'],
        response_types: ['code'],
        token_endpoint_auth_method: 'none',
        scope: SCOPE,
      },
      201,
    )
  })

  .get('/oauth/authorize', async ({ query }) => {
    const authz = await readAuthz(query as Record<string, unknown>)
    if ('error' in authz) {
      if (!authz.redirect) return errorPage(authz.error)
      return redirectError({ redirectUri: str((query as Record<string, unknown>).redirect_uri), state: str((query as Record<string, unknown>).state) }, authz.error)
    }
    return signInPage(authz)
  })

  // Sign-in form submit: validate the pasted API token, then hand back a one-time code.
  .post('/oauth/authorize', async ({ body }) => {
    const form = (body ?? {}) as Record<string, unknown>
    const authz = await readAuthz(form)
    if ('error' in authz) {
      if (!authz.redirect) return errorPage(authz.error)
      return redirectError({ redirectUri: str(form.redirect_uri), state: str(form.state) }, authz.error)
    }

    const uid = resolveStaticToken(str(form.token))
    if (!uid) return signInPage(authz, 'That token is not valid for this server.')

    const code = secret()
    await codes.doc(hash(code)).set({
      uid,
      clientId: authz.clientId,
      redirectUri: authz.redirectUri,
      challenge: authz.challenge,
      scope: authz.scope,
      resource: authz.resource,
      expiresAt: Timestamp.fromMillis(Date.now() + CODE_TTL_MS),
    })

    const url = new URL(authz.redirectUri)
    url.searchParams.set('code', code)
    if (authz.state) url.searchParams.set('state', authz.state)
    return redirectTo(url.toString())
  })

  .post('/oauth/token', async ({ body }) => {
    const form = (body ?? {}) as Record<string, unknown>
    const grant = str(form.grant_type)
    const clientId = str(form.client_id)

    if (grant === 'authorization_code') {
      const ref = codes.doc(hash(str(form.code)))
      const doc = await ref.get()
      if (!doc.exists) return oauthError('invalid_grant', 'Unknown or already used authorization code')
      await ref.delete() // one-time use, whatever happens next
      if (isExpired(doc.get('expiresAt'))) return oauthError('invalid_grant', 'Authorization code expired')
      if (doc.get('clientId') !== clientId) return oauthError('invalid_grant', 'Code was issued to another client')
      if (doc.get('redirectUri') !== str(form.redirect_uri)) return oauthError('invalid_grant', 'redirect_uri mismatch')

      const verifier = str(form.code_verifier)
      if (!verifier || challengeOf(verifier) !== doc.get('challenge')) return oauthError('invalid_grant', 'PKCE verification failed')

      return json(await issueTokens(str(doc.get('uid')), clientId))
    }

    if (grant === 'refresh_token') {
      const ref = tokens.doc(hash(str(form.refresh_token)))
      const doc = await ref.get()
      if (!doc.exists || doc.get('kind') !== 'refresh' || isExpired(doc.get('expiresAt'))) {
        return oauthError('invalid_grant', 'Unknown or expired refresh token')
      }
      if (doc.get('clientId') !== clientId) return oauthError('invalid_grant', 'Refresh token was issued to another client')
      await ref.delete() // rotate
      return json(await issueTokens(str(doc.get('uid')), clientId))
    }

    return oauthError('unsupported_grant_type', `Unsupported grant_type: ${grant || '(missing)'}`)
  })

  // RFC 7009. Takes an access or refresh token; always answers 200 so a revoked or unknown token
  // cannot be told apart. Revoking an access token drops the refresh token issued with it too.
  .post('/oauth/revoke', async ({ body }) => {
    const form = (body ?? {}) as Record<string, unknown>
    const token = str(form.token)
    if (token) {
      const ref = tokens.doc(hash(token))
      const doc = await ref.get()
      if (doc.exists) {
        const uid = str(doc.get('uid'))
        const clientId = str(doc.get('clientId'))
        await ref.delete()
        // Drop the sibling token from the same grant, so revoking one does not leave the other live.
        const siblings = await tokens.where('uid', '==', uid).where('clientId', '==', clientId).get()
        await Promise.all(siblings.docs.map((d) => d.ref.delete()))
      }
    }
    return json({ revoked: true })
  })
