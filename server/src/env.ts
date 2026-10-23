// Runtime configuration, read once at startup.

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
}

if (env.tokens.size === 0) {
  console.warn('[env] API_TOKENS is empty — every authenticated route will return 401.')
}
