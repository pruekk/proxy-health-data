import { Elysia } from 'elysia'
import { resolveStaticToken } from './env'
import { baseUrl, resolveAccessToken } from './oauth'

// Bearer-token auth. Adds `uid` to the context of every route registered after `.use(auth)`.
// Two kinds of token are accepted: the long-lived API_TOKENS entries (iOS app, Claude Code header
// config) and the short-lived access tokens issued by the OAuth flow in oauth.ts (Claude connectors).
export const auth = new Elysia({ name: 'auth' })
  .resolve({ as: 'scoped' }, async ({ headers }) => {
    const header = headers.authorization ?? ''
    const token = header.toLowerCase().startsWith('bearer ') ? header.slice(7).trim() : ''
    return { uid: resolveStaticToken(token) ?? (await resolveAccessToken(token)) ?? '' }
  })
  .onBeforeHandle({ as: 'scoped' }, ({ uid, set, headers }) => {
    if (!uid) {
      set.status = 401
      // Points MCP clients at the metadata that kicks off the OAuth flow (RFC 9728 §5.1).
      set.headers['www-authenticate'] = `Bearer resource_metadata="${baseUrl(headers)}/.well-known/oauth-protected-resource"`
      set.headers['access-control-allow-origin'] = '*'
      set.headers['access-control-expose-headers'] = 'www-authenticate'
      return { error: 'unauthorized' }
    }
  })
