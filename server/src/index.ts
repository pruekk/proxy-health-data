import { Elysia, t } from 'elysia'
import { auth } from './auth'
import { catalog } from './catalog'
import { defaults as retentionDefaults, validate as validateRetention } from './retention'
import { computeBattery } from './battery'
import { parseDateKeys, parseRange } from './dates'
import { env } from './env'
import { handleMcp } from './mcp'
import { listUserConnectors, oauth, revokeUserTokens } from './oauth'
import { SyncBody, SyncLogInput } from './schemas'
import {
  BadRequest,
  applyRetention,
  collectBatteryInputs,
  deleteAllData,
  getProfile,
  getReadiness,
  heartRateZonesFor,
  getRetention,
  ingest,
  listMetrics,
  listSyncs,
  queryDaily,
  queryHourly,
  querySamples,
  querySleep,
  queryWorkouts,
  recordSync,
  setRetention,
} from './store'

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
      // The metric catalog the app syncs. Served from here so adding a metric is a deploy
      // rather than a rebuild; `version` lets the app skip the work when nothing changed.
      .get('/catalog', ({ query, set }) => {
        if (query.version === catalog.version) {
          set.status = 304
          return ''
        }
        return catalog
      }, { query: t.Object({ version: t.Optional(t.String({ maxLength: 64 })) }) })
      // Signs this user's connectors out everywhere. The static API token still works, so the
      // iOS app and Claude Code keep syncing.
      .get('/connectors', ({ uid }) => listUserConnectors(uid))
      .post('/revoke-connectors', async ({ uid }) => ({ ok: true, revoked: await revokeUserTokens(uid) }))
      .post('/sync', async ({ uid, body }) => ({ ok: true, written: await ingest(uid, body) }), {
        body: SyncBody,
      })
      .get('/metrics', ({ uid, query }) => listMetrics(uid, undefined, false, query.counts === 'true'), {
        query: t.Object({ counts: t.Optional(t.String()) }),
      })
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
      // Training readiness: one number for "should I train hard today?". Computed once a day
      // and then served from storage, so it does not drift between app opens.
      .get('/readiness', ({ uid }) => getReadiness(uid))
      // How much is left right now, as opposed to how recovered the morning started.
      .get('/battery', async ({ uid }) => computeBattery(await collectBatteryInputs(uid)))
      // Training zones, from the heart rate actually recorded rather than an age formula.
      .get('/zones', ({ uid }) => heartRateZonesFor(uid))
      .get(
        '/hourly',
        async ({ uid, query }) => {
          const keys = parseDateKeys(query.from, query.to, 3, await timeZoneOf(uid))
          return queryHourly(uid, keys.from, keys.to)
        },
        { query: RangeQuery },
      )

      // ----- sync history: kept server-side so it survives a reinstall -----
      .get('/syncs', ({ uid, query }) => listSyncs(uid, query.limit ?? 50), { query: RangeQuery })
      .post(
        '/syncs',
        async ({ uid, body }) => {
          await recordSync(uid, body)
          return { ok: true }
        },
        { body: SyncLogInput },
      )

      // ----- settings and housekeeping -----
      // Retention is per group; the groups themselves, their windows and the wording the app
      // shows come from the catalog, so adding one is a deploy rather than a rebuild.
      .get('/settings', async ({ uid }) => ({
        retention: await getRetention(uid),
        groups: catalog.retentionGroups,
        defaults: retentionDefaults,
      }))
      .put(
        '/settings',
        async ({ uid, body, set }) => {
          try {
            const changes = validateRetention((body.retention ?? {}) as Record<string, unknown>)
            return { ok: true, retention: await setRetention(uid, changes) }
          } catch (error) {
            set.status = 400
            return { error: error instanceof Error ? error.message : 'invalid retention' }
          }
        },
        { body: t.Object({ retention: t.Optional(t.Record(t.String(), t.Integer())) }) },
      )
      // One-off housekeeping: stamps `expiresAt` on documents written before retention existed.
      // One scope per call (a metric type, or daily/hourly/workouts) to stay inside the timeout.
      .post(
        '/retention/apply',
        ({ uid, query }) => applyRetention(uid, query.scope, query.dryRun !== 'false', query.after),
        {
          query: t.Object({
            scope: t.String({ maxLength: 80 }),
            dryRun: t.Optional(t.String()),
            // Resume point from a previous call that ran out of budget.
            after: t.Optional(t.String({ maxLength: 200 })),
          }),
        },
      )
      // Deletes every health document for this user; profile, token and connectors stay.
      .delete('/data', async ({ uid }) => {
        await deleteAllData(uid)
        return { ok: true }
      })
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
