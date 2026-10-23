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
  HRV, HR recovery, SpO₂, respiratory rate, VO₂ max, blood pressure, weight, body fat, lean mass,
  BMI, wrist temperature, walking/running metrics, sleep stages, mindful sessions, heart events.
- **Workouts** (Apple Watch / Fitness / Fitness+ / third-party): type, duration, energy, distance,
  HR avg/min/max, steps, power, speed, elevation, indoor flag.
- **Daily aggregates** per metric (sum or avg/min/max via `HKStatisticsCollectionQuery`, which
  removes iPhone + Watch double counting).
- **Activity rings** (`HKActivitySummary`): move/exercise/stand and goals.

## Firestore layout

```
users/{uid}                                 timeZone, lastSyncAt
users/{uid}/metrics/{type}                  kind, unit, lastSyncAt
users/{uid}/metrics/{type}/samples/{uuid}   value, unit, valueLabel, startDate, endDate, source…
users/{uid}/workouts/{uuid}                 activityTypeName, durationSec, activeEnergyKcal…
users/{uid}/daily/{yyyy-MM-dd}              metrics.{type}.{sum|avg|min|max}, activity.{rings}
```

All queries use single-field indexes, so no composite indexes are needed.

## Server

```bash
cd server
bun install
cp .env.example .env            # set API_TOKENS=<token>:<userId>
gcloud auth application-default login   # local Firestore credentials
bun run dev                     # http://localhost:3000
```

Credentials: `FIREBASE_SERVICE_ACCOUNT` (inline JSON) if set, otherwise Application Default
Credentials (`GOOGLE_APPLICATION_CREDENTIALS`, gcloud ADC, or the Cloud Run service account).

### REST (all need `Authorization: Bearer <token>`)

| Route | |
| --- | --- |
| `GET /health` | liveness (no auth) |
| `GET /v1/me` | profile for the token's user |
| `POST /v1/sync` | iOS upload: `samples`, `deletedSamples`, `workouts`, `deletedWorkoutIds`, `dailyStats`, `activitySummaries` |
| `GET /v1/metrics` | metric list + latest sample |
| `GET /v1/metrics/:type/samples?from&to&limit` | raw samples |
| `GET /v1/workouts?from&to&activityType&limit` | workouts |
| `GET /v1/daily?from=YYYY-MM-DD&to=YYYY-MM-DD` | daily aggregates + rings |
| `GET /v1/sleep?from&to` | nightly sleep summary |

### MCP

`POST /mcp` — stateless Streamable HTTP MCP server (JSON responses). Tools:
`list_metrics`, `get_daily_summaries`, `get_samples`, `get_workouts`, `get_sleep`.

Claude Code:

```bash
claude mcp add --transport http proxy-health https://<server>/mcp --header "Authorization: Bearer <token>"
```

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
