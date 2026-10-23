// Runtime configuration, read once at startup.

import { timingSafeEqual } from 'node:crypto'

function parseTokens(raw: string): Map<string, string> {
  // API_TOKENS="tokenA:userA,tokenB:userB" — each bearer token maps to one Firestore user id.
  const tokens = new Map<string, string>()
  for (const pair of raw.split(',')) {
    const [token, uid] = pair.split(':').map((s) => s.trim())
    if (token && uid) tokens.set(token, uid)
  }
  return tokens
}

export const env = {
  port: Number(process.env.PORT ?? 3000),
  projectId: process.env.FIREBASE_PROJECT_ID ?? 'proxy-health-data',
  databaseId: process.env.FIRESTORE_DATABASE_ID ?? '(default)',
  tokens: parseTokens(process.env.API_TOKENS ?? ''),
  // Optional: pins the OAuth issuer when the API sits behind a custom domain. Otherwise the
  // request's host is used, so every Cloud Run hostname keeps working.
  publicUrl: process.env.PUBLIC_URL ?? '',
}

if (env.tokens.size === 0) {
  console.warn('[env] API_TOKENS is empty — every authenticated route will return 401.')
}

// Resolves one of the long-lived API_TOKENS (iOS app, `claude mcp add --header`, OAuth sign-in form).
export function resolveStaticToken(token: string): string | null {
  if (!token) return null
  const given = Buffer.from(token)
  for (const [known, uid] of env.tokens) {
    const expected = Buffer.from(known)
    if (expected.length === given.length && timingSafeEqual(expected, given)) return uid
  }
  return null
}
