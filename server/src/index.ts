import { Elysia, t } from 'elysia'
import { auth } from './auth'
import { parseDateKeys, parseRange } from './dates'
import { env } from './env'
import { handleMcp } from './mcp'
import { oauth, revokeUserTokens } from './oauth'
import { SyncBody } from './schemas'
import { BadRequest, getProfile, ingest, listMetrics, queryDaily, querySamples, querySleep, queryWorkouts } from './store'

const RangeQuery = t.Object({
  from: t.Optional(t.String()),
  to: t.Optional(t.String()),
  limit: t.Optional(t.Numeric({ minimum: 1, maximum: 1000 })),
})

const timeZoneOf = async (uid: string) => String((await getProfile(uid)).timeZone ?? 'UTC')

export const app = new Elysia()
  .error({ BadRequest })
  .onError(({ code, error, set }) => {
    if (code === 'BadRequest') {
      set.status = 400
      return { error: error.message }
    }
    if (code === 'VALIDATION') return
    if (code === 'NOT_FOUND') return { error: 'not found' }
    console.error('[server]', error)
    set.status = 500
    return { error: 'internal error' }
  })
  // Browser-based MCP clients do discovery with fetch(), so every response needs CORS.
  .onAfterHandle({ as: 'global' }, ({ set }) => {
    set.headers['access-control-allow-origin'] ??= '*'
    set.headers['access-control-expose-headers'] ??= 'www-authenticate'
  })
  .options('/*', ({ set }) => {
    set.status = 204
    set.headers['access-control-allow-origin'] = '*'
    set.headers['access-control-allow-methods'] = 'GET, POST, DELETE, OPTIONS'
    set.headers['access-control-allow-headers'] = 'authorization, content-type, mcp-protocol-version'
    set.headers['access-control-max-age'] = '86400'
    return ''
  })
  .get('/', () => ({ name: 'proxy-health-data', endpoints: ['/health', '/v1/*', '/mcp', '/oauth/*'] }))
  .get('/health', () => ({ status: 'ok' }))

  // ----- OAuth for Claude connectors (discovery, registration, sign-in, token) -----
  .use(oauth)

  // ----- REST API used by the iOS app (and handy for debugging) -----
  .group('/v1', (v1) =>
    v1
      .use(auth)
      .get('/me', ({ uid }) => getProfile(uid))
      // Signs this user's connectors out everywhere. The static API token still works, so the
      // iOS app and Claude Code keep syncing.
      .post('/revoke-connectors', async ({ uid }) => ({ ok: true, revoked: await revokeUserTokens(uid) }))
      .post('/sync', async ({ uid, body }) => ({ ok: true, written: await ingest(uid, body) }), {
        body: SyncBody,
      })
      .get('/metrics', ({ uid }) => listMetrics(uid))
      .get(
        '/metrics/:type/samples',
        ({ uid, params, query }) => querySamples(uid, params.type, parseRange(query.from, query.to, 7), query.limit ?? 200),
        { params: t.Object({ type: t.String({ pattern: '^[A-Za-z0-9_]{1,80}$' }) }), query: RangeQuery },
      )
      .get(
        '/workouts',
        ({ uid, query }) => queryWorkouts(uid, parseRange(query.from, query.to, 30), query.limit ?? 50, query.activityType),
        { query: t.Composite([RangeQuery, t.Object({ activityType: t.Optional(t.String()) })]) },
      )
      .get(
        '/daily',
        async ({ uid, query }) => {
          const keys = parseDateKeys(query.from, query.to, 7, await timeZoneOf(uid))
          return queryDaily(uid, keys.from, keys.to)
        },
        { query: RangeQuery },
      )
      .get(
        '/sleep',
        async ({ uid, query }) => querySleep(uid, parseRange(query.from, query.to, 7), await timeZoneOf(uid)),
        { query: RangeQuery },
      ),
  )

  // ----- MCP (Streamable HTTP, stateless) -----
  .group('/mcp', (mcp) =>
    mcp
      .use(auth)
      .post('/', async ({ uid, body, set }) => {
        const response = await handleMcp(uid, body)
        if (response === null) {
          set.status = 202
          return ''
        }
        return response
      })
      // No server-initiated stream and no sessions in stateless mode.
      .get('/', ({ set }) => {
        set.status = 405
        set.headers.allow = 'POST'
        return { error: 'method not allowed' }
      })
      .delete('/', ({ set }) => {
        set.status = 405
        set.headers.allow = 'POST'
        return { error: 'method not allowed' }
      }),
  )

if (import.meta.main) {
  app.listen({ port: env.port, hostname: '0.0.0.0' })
  console.log(`proxy-health-data server on http://localhost:${env.port} (project ${env.projectId})`)
}
