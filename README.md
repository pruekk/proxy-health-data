# proxy-health-data

Sync Apple Health + Apple Fitness data from iPhone into Firestore (Firebase project
`proxy-health-data`, number 569148641622) and expose it to AI assistants over MCP.

```
iPhone (HealthKit) ──POST /v1/sync──▶ Elysia server (Bun) ──▶ Firestore
                                          │
                       AI client ──POST /mcp (JSON-RPC, Bearer token)
```

## Layout

| Path | What |
| --- | --- |
| `ios/` | SwiftUI app `ProxyHealth` (iOS 17+). Reads HealthKit, uploads deltas. |
| `server/` | Elysia API + MCP endpoint, firebase-admin → Firestore. |
| `firestore.rules` | Denies direct client access; only the server (admin SDK) reads/writes. |

## What is synced

- **Raw samples** (anchored queries, only changes since last sync, deletions too): steps, distance,
  active/basal energy, exercise/stand/move minutes, daylight, heart rate, resting HR, walking HR,
  HRV, HR recovery, SpO₂, respiratory rate, VO₂ max, blood pressure, weight, height, body fat, lean
  mass, BMI, waist, body and wrist temperature, walking/running metrics, sleep stages, mindful
  sessions, heart events, low-cardio-fitness notifications.
- **Characteristics**: date of birth and biological sex, uploaded once (and again only if they
  change). They are what lets a VO₂ max number be read as a fitness level.
- **Workouts** (Apple Watch / Fitness / Fitness+ / third-party): type, duration, energy, distance,
  HR avg/min/max, steps, power, speed, elevation, indoor flag.
- **Daily aggregates** per metric (sum or avg/min/max via `HKStatisticsCollectionQuery`, which
  removes iPhone + Watch double counting).
- **Activity rings** (`HKActivitySummary`): move/exercise/stand and goals.

How far back the **first** sync reaches is per metric (`Backfill` in `HealthCatalog.swift`):

| Policy | Metrics | Why |
| --- | --- | --- |
| `.all` | body measurements, VO₂ max, HR recovery | a handful of samples a month; VO₂ max history can be years old |
| `.extended` (2 years) | resting HR, walking HR, HRV, blood pressure, heart events, mindful sessions | a few samples a week |
| `.standard` (Settings, 7 days) | heart rate, steps, distance, energy, sleep, running form | all-day types where one Firestore doc per sample adds up fast |

Changing a metric's policy drops its stored anchor (`SyncState.applyBackfillPolicy`), otherwise a
widened window would be silently ignored — the old anchor already points past the history. Daily
aggregates and workouts use the Settings window (730 days by default; one doc per day is cheap).

Workouts additionally get their raw heart rate and speed pulled per session, including a 10-minute
recovery tail, so older runs can still be reviewed for drift, zones and splits without keeping every
heart-rate sample ever recorded. Each workout is fetched once (`SyncState.workoutDetailDone`).

After the first sync, anchors and background delivery keep everything current on their own — there is
nothing to re-run for new data.

## Firestore layout

```
users/{uid}                                 timeZone, lastSyncAt, dateOfBirth, biologicalSex
users/{uid}/metrics/{type}                  kind, unit, lastSyncAt
users/{uid}/metrics/{type}/samples/{uuid}   value, unit, valueLabel, startDate, endDate, source…
users/{uid}/workouts/{uuid}                 activityTypeName, durationSec, activeEnergyKcal…
users/{uid}/daily/{yyyy-MM-dd}              metrics.{type}.{sum|avg|min|max}, activity.{rings}
oauthClients|oauthCodes|oauthTokens        OAuth connector state (see MCP below)
```

All queries use single-field indexes, so no composite indexes are needed.

## Server

```bash
cd server
bun install
cp .env.example .env            # set API_TOKENS=<token>:<userId>
gcloud auth application-default login   # local Firestore credentials
bun run dev                     # http://localhost:3000
test/run.sh                     # end-to-end tests (starts its own Firestore emulator)
```

`test/run.sh` boots the emulator with open rules and a stub token endpoint, runs every suite against
a throwaway database (one token per suite, so they cannot see each other's data) and tears it all
down. Production is never touched. Needs `java` for the emulator.

Credentials: `FIREBASE_SERVICE_ACCOUNT` (inline JSON) if set, otherwise Application Default
Credentials (`GOOGLE_APPLICATION_CREDENTIALS`, gcloud ADC, or the Cloud Run service account).

### REST (all need `Authorization: Bearer <token>`)

| Route | |
| --- | --- |
| `GET /health` | liveness (no auth) |
| `GET /v1/me` | profile for the token's user |
| `POST /v1/revoke-connectors` | drops every OAuth token this user holds; the static token keeps working |
| `POST /v1/sync` | iOS upload: `samples`, `deletedSamples`, `workouts`, `deletedWorkoutIds`, `dailyStats`, `activitySummaries`, `profile` |
| `GET /v1/metrics` | metric list + latest sample |
| `GET /v1/metrics/:type/samples?from&to&limit` | raw samples |
| `GET /v1/workouts?from&to&activityType&limit` | workouts |
| `GET /v1/daily?from=YYYY-MM-DD&to=YYYY-MM-DD` | daily aggregates + rings |
| `GET /v1/sleep?from&to` | nightly sleep summary |

### MCP

`POST /mcp` — stateless Streamable HTTP MCP server (JSON responses). Tools:

| Tool | |
| --- | --- |
| `list_metrics` | every synced metric with unit, kind and latest sample, plus the profile |
| `get_daily_summaries` | per-day sums / avg-min-max and activity rings |
| `get_samples` | raw samples for one metric |
| `get_workouts` | workouts, newest first |
| `get_sleep` | nightly sleep stages |
| `get_latest_values` | current value of just the metrics you name — far cheaper than `list_metrics` |
| `get_metric_stats` | first/last/change/avg/min/max per metric over a range ("is my VO₂ max improving?") |
| `get_body_composition` | weight, height, BMI, body fat, lean mass, waist as one series; BMI derived when absent |
| `get_cardio_fitness` | VO₂ max trend and level, with resting HR, HRV and HR recovery alongside |
| `get_workout_detail` | one workout plus its raw HR and speed series, including a recovery tail after it ends |

`list_metrics` takes `withSources` to show which apps and devices report each metric, and
`get_samples` takes a `source` filter. Several sources per metric is normal (Apple Watch, iPhone and
a third-party ring can all log steps) — daily aggregates are de-duplicated on-device, **raw samples
are not**, so never sum raw samples for a total.

`get_latest_values` falls back to the most recent daily aggregate when a metric has no recent raw
sample (weight is weighed less often than the 7-day raw window), and says which it used in a `from`
field. Workout weather is normalised on read: HealthKit reports it as formatted strings
(`HKWeatherTemperature: "78.26 degF"`, `HKWeatherHumidity: "9000 %"` — hundredths of a percent), so
`weatherTempC` and `weatherHumidityPercent` are added alongside the untouched metadata.

`get_cardio_fitness` labels VO₂ max low / below average / above average / high using Cooper
Institute percentiles (25th/50th/75th) for the user's age band and sex. Apple does not publish the
cutoffs behind its own Cardio Fitness levels — they exist only inside the Health app — so the
numbers will not always agree with what Apple shows. Every response says so in a `basis` field.

Two ways to authenticate, both ending at the same `uid`:

**Static token** — simplest, for Claude Code and the iOS app:

```bash
claude mcp add --transport http proxy-health https://<server>/mcp --header "Authorization: Bearer <token>"
```

**OAuth** — required by Claude connectors (claude.ai and the mobile apps cannot send a custom
header). Add a custom connector pointing at `https://<server>/mcp`, pick *Sign in now*, and paste an
API token on the sign-in page Claude opens. `server/src/oauth.ts` implements the minimum the
connector flow needs:

| Endpoint | |
| --- | --- |
| `GET /.well-known/oauth-protected-resource[/mcp]` | resource metadata (RFC 9728), points at the issuer |
| `GET /.well-known/oauth-authorization-server[/mcp]` | AS metadata (RFC 8414) |
| `POST /oauth/register` | dynamic client registration (RFC 7591), public clients, no secret |
| `GET\|POST /oauth/authorize` | sign-in page; exchanges an API token for a one-time code |
| `POST /oauth/token` | code (PKCE S256) or refresh token → access token |
| `POST /oauth/revoke` | revokes an access or refresh token (RFC 7009), always answers 200 |

The API token is still the only credential: registration is open, but a client id alone gets
nothing. Access tokens last 30 days, refresh tokens 180 and rotate on use; codes are single-use and
expire after 10 minutes. Codes and tokens are stored hashed in `oauthCodes`/`oauthTokens`, clients in
`oauthClients` — all with an `expiresAt` field, so you can add a Firestore TTL policy on it to sweep
old docs. Unauthenticated `/mcp` requests answer `401` with a `WWW-Authenticate: Bearer
resource_metadata=…` header, which is what starts the flow.

The issuer is derived from the request host, so both Cloud Run hostnames work; set `PUBLIC_URL` to
pin it behind a custom domain.

### Deploy to Cloud Run

Live at `https://proxy-health-api-569148641622.asia-southeast1.run.app` (MCP: `/mcp`).

```bash
cd server
gcloud run deploy proxy-health-api --source . --project proxy-health-data --region asia-southeast1 \
  --build-service-account projects/proxy-health-data/serviceAccounts/proxy-health-build@proxy-health-data.iam.gserviceaccount.com \
  --service-account proxy-health-api@proxy-health-data.iam.gserviceaccount.com \
  --set-secrets API_TOKENS=api-tokens:latest --set-env-vars FIREBASE_PROJECT_ID=proxy-health-data \
  --allow-unauthenticated --memory 512Mi --max-instances 3
```

- `proxy-health-api` SA (runtime): `roles/datastore.user`, secret accessor on `api-tokens`.
- `proxy-health-build` SA (Cloud Build): `roles/run.builder`.
- Rotate or add tokens: `printf 'tokenA:me,tokenB:other' | gcloud secrets versions add api-tokens --data-file=- --project proxy-health-data`,
  then redeploy (or `gcloud run services update proxy-health-api --region asia-southeast1`) so a new revision reads `latest`.

## iOS app

1. Open `ios/ProxyHealth.xcodeproj` in Xcode.
2. Target → Signing & Capabilities: pick your Team (the HealthKit capability and background
   delivery are already in `ProxyHealth.entitlements`). Change the bundle id if needed.
3. Run on your iPhone, tap **Connect Apple Health**, then **Settings** → server URL + token.
4. **Sync now**. After that the app syncs on open and in the background via HealthKit
   observer queries (`enableBackgroundDelivery`).

Known issue: iOS 26.5 leaves Blood Pressure out of the HealthKit permission sheet
([Apple forum thread](https://developer.apple.com/forums/thread/825866)); the app then logs
"Authorization not determined" for `bloodPressure*`. Turn it on manually in Settings → Privacy &
Security → Health → Proxy Health.

On a device, `localhost` is the phone — use your Mac's LAN IP (`http://192.168.x.x:3000`) or the
deployed HTTPS URL. First sync backfills 7 days of raw samples and 90 days of daily summaries and
workouts (configurable in Settings); raw heart-rate history is the bulk of Firestore writes.
