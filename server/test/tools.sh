#!/bin/bash
# Exercises the new MCP tools against a seeded local server.
set -uo pipefail
B=${B:-http://localhost:3030}
AUTH="authorization: Bearer $TOKEN"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected [$2] got [$3]"; fail=$((fail+1)); fi; }
call() { curl -s -X POST $B/mcp -H "$AUTH" -H 'content-type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["content"][0]["text"])'; }

echo "0. seed"
python3 - "$B" "$TOKEN" <<'PY'
import json, sys, urllib.request
from datetime import date, timedelta, datetime, timezone
base, token = sys.argv[1], sys.argv[2]
def post(payload):
    req = urllib.request.Request(base + "/v1/sync", data=json.dumps(payload).encode(),
        headers={"content-type": "application/json", "authorization": "Bearer " + token})
    return json.load(urllib.request.urlopen(req))
# characteristics
post({"timeZone": "Asia/Bangkok", "profile": {"dateOfBirth": "1990-05-15", "biologicalSex": "male"}})
# 10 days of daily aggregates: VO2 max climbing 40.0 -> 42.0, weight falling, height constant, no BMI
stats, samples = [], []
for i in range(10):
    d = (date.today() - timedelta(days=9 - i)).isoformat()
    stats += [
        {"date": d, "type": "vo2Max", "unit": "ml/(kg*min)", "avg": 40.0 + i * 0.22, "min": 39.5 + i * 0.2, "max": 40.5 + i * 0.25},
        {"date": d, "type": "bodyMass", "unit": "kg", "avg": 78.0 - i * 0.15, "min": 77.8 - i * 0.15, "max": 78.2 - i * 0.15},
        {"date": d, "type": "height", "unit": "m", "avg": 1.75, "min": 1.75, "max": 1.75},
        {"date": d, "type": "restingHeartRate", "unit": "count/min", "avg": 58 - i * 0.2, "min": 55, "max": 62},
        {"date": d, "type": "stepCount", "unit": "count", "sum": 8000 + i * 100},
    ]
ts = datetime.now(timezone.utc).isoformat()
samples = [
    {"id": "11111111-1111-1111-1111-111111111111", "type": "bodyMass", "kind": "quantity", "value": 76.65,
     "unit": "kg", "startDate": ts, "endDate": ts, "sourceName": "Withings"},
    {"id": "22222222-2222-2222-2222-222222222222", "type": "height", "kind": "quantity", "value": 1.75,
     "unit": "m", "startDate": ts, "endDate": ts, "sourceName": "Health"},
    {"id": "33333333-3333-3333-3333-333333333333", "type": "vo2Max", "kind": "quantity", "value": 41.98,
     "unit": "ml/(kg*min)", "startDate": ts, "endDate": ts, "sourceName": "Apple Watch"},
]
post({"timeZone": "Asia/Bangkok", "dailyStats": stats, "samples": samples})
print("  seeded", len(stats), "daily stats and", len(samples), "samples")
PY

echo "1. profile characteristics"
ME=$(curl -s $B/v1/me -H "$AUTH")
check "dateOfBirth stored" "1990-05-15" "$(echo "$ME" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("dateOfBirth"))')"
check "biologicalSex stored" "male" "$(echo "$ME" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("biologicalSex"))')"

echo "2. tools/list"
check "tool count" "13" "$(curl -s -X POST $B/mcp -H "$AUTH" -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["result"]["tools"]))')"

echo "3. get_latest_values"
LV=$(call get_latest_values '{"types":["bodyMass","height","vo2Max"]}')
check "three metrics" "3" "$(echo "$LV" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["values"]))')"
check "weight value" "76.65" "$(echo "$LV" | python3 -c 'import sys,json;print([v["value"] for v in json.load(sys.stdin)["values"] if v["type"]=="bodyMass"][0])')"
check "height value" "1.75" "$(echo "$LV" | python3 -c 'import sys,json;print([v["value"] for v in json.load(sys.stdin)["values"] if v["type"]=="height"][0])')"
check "source kept" "Apple Watch" "$(echo "$LV" | python3 -c 'import sys,json;print([v["source"] for v in json.load(sys.stdin)["values"] if v["type"]=="vo2Max"][0])')"

echo "4. get_metric_stats"
MS=$(call get_metric_stats '{"types":["vo2Max","bodyMass"]}')
check "vo2 days" "10" "$(echo "$MS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["metrics"]["vo2Max"]["days"])')"
check "vo2 change +1.98" "1.98" "$(echo "$MS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["metrics"]["vo2Max"]["change"])')"
check "weight change -1.35" "-1.35" "$(echo "$MS" | python3 -c 'import sys,json;print(json.load(sys.stdin)["metrics"]["bodyMass"]["change"])')"
check "unknown metric reports no data" "0" "$(call get_metric_stats '{"types":["nothingHere"]}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["metrics"]["nothingHere"]["days"])')"
check "missing types rejected" "1" "$(call get_metric_stats '{}' | grep -ci 'Error')"

echo "5. get_body_composition"
BC=$(call get_body_composition '{}')
check "derived BMI present" "25" "$(echo "$BC" | python3 -c 'import sys,json;print(json.load(sys.stdin)["days"][-1]["derivedBodyMassIndex"])')"
check "weight in series" "76.65" "$(echo "$BC" | python3 -c 'import sys,json;print(round(json.load(sys.stdin)["days"][-1]["bodyMass"],2))')"
check "latest height" "1.75" "$(echo "$BC" | python3 -c 'import sys,json;print(json.load(sys.stdin)["latest"]["height"]["avg"])')"

echo "6. get_cardio_fitness"
CF=$(call get_cardio_fitness '{}')
check "current vo2" "41.98" "$(echo "$CF" | python3 -c 'import sys,json;print(round(json.load(sys.stdin)["vo2Max"]["current"],2))')"
check "age computed" "36" "$(echo "$CF" | python3 -c 'import sys,json;print(json.load(sys.stdin)["age"])')"
check "age band 30-39" "30-39" "$(echo "$CF" | python3 -c 'import sys,json;print(json.load(sys.stdin)["vo2Max"]["classification"]["ageBand"])')"
check "level below average" "below average" "$(echo "$CF" | python3 -c 'import sys,json;print(json.load(sys.stdin)["vo2Max"]["classification"]["level"])')"
check "basis disclosed" "1" "$(echo "$CF" | grep -ci "not Apple")"
check "resting HR summarised" "10" "$(echo "$CF" | python3 -c 'import sys,json;print(json.load(sys.stdin)["supporting"]["restingHeartRate"]["days"])')"

echo "7. source awareness"
SRC=$(call list_metrics '{"withSources":true}')
check "sources reported" "1" "$(echo "$SRC" | python3 -c 'import sys,json;m=json.load(sys.stdin)["metrics"];print(1 if any("sources" in x for x in m) else 0)')"
check "source name kept" "Withings" "$(echo "$SRC" | python3 -c 'import sys,json;m=[x for x in json.load(sys.stdin)["metrics"] if x["type"]=="bodyMass"][0];print(m["sources"][0]["source"])')"
check "omitted by default" "0" "$(call list_metrics '{}' | python3 -c 'import sys,json;m=json.load(sys.stdin)["metrics"];print(sum(1 for x in m if "sources" in x))')"
check "source filter matches" "1" "$(call get_samples '{"type":"bodyMass","source":"withings"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["count"])')"
check "source filter excludes" "0" "$(call get_samples '{"type":"bodyMass","source":"garmin"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["count"])')"

echo "8. payload slimming"
check "floats rounded" "1" "$(call get_daily_summaries '{"from":"2026-01-01","to":"2026-12-31"}' | grep -c '40.22' || true)"
check "no null fields" "0" "$(call get_latest_values '{}' | grep -c ': null' || true)"
FULL=$(call get_daily_summaries '{"from":"2026-01-01","to":"2026-12-31"}' | wc -c)
NARROW=$(call get_daily_summaries '{"from":"2026-01-01","to":"2026-12-31","fields":["avg"]}' | wc -c)
check "fields filter shrinks response" "1" "$([ "$NARROW" -lt "$FULL" ] && echo 1 || echo 0)"
check "fields filter keeps avg only" "1" "$(call get_daily_summaries '{"from":"2026-01-01","to":"2026-12-31","fields":["avg"]}' | python3 -c 'import sys,json;d=json.load(sys.stdin)["days"];ks={k for day in d for m in day.get("metrics",{}).values() for k in m};print(1 if ks=={"avg"} else 0)')"

echo "9. catalog is served"
CAT=$(curl -s $B/v1/catalog -H "$AUTH")
check "has a version" "1" "$(echo "$CAT" | python3 -c 'import sys,json;print(1 if len(json.load(sys.stdin)["version"])>=8 else 0)')"
check "quantities present" "1" "$(echo "$CAT" | python3 -c 'import sys,json;print(1 if len(json.load(sys.stdin)["quantities"])>30 else 0)')"
check "identifiers look right" "HKQuantityTypeIdentifierVO2Max" "$(echo "$CAT" | python3 -c 'import sys,json;print([q["identifier"] for q in json.load(sys.stdin)["quantities"] if q["key"]=="vo2Max"][0])')"
VER=$(echo "$CAT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["version"])')
check "unchanged version -> 304" "304" "$(curl -s -o /dev/null -w '%{http_code}' "$B/v1/catalog?version=$VER" -H "$AUTH")"
check "stale version -> 200" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$B/v1/catalog?version=old" -H "$AUTH")"

echo "10. denormalised metric reads"
check "latest from metric doc" "76.65" "$(call get_latest_values '{"types":["bodyMass"]}' | python3 -c 'import sys,json;print([v["value"] for v in json.load(sys.stdin)["values"] if v["type"]=="bodyMass"][0])')"
check "sources counted at ingest" "Withings" "$(call list_metrics '{"withSources":true}' | python3 -c 'import sys,json;m=[x for x in json.load(sys.stdin)["metrics"] if x["type"]=="bodyMass"][0];print(m["sources"][0]["source"])')"

echo "11. retention tiers"
python3 - "$B" "$TOKEN" <<'PY2'
import json, sys, urllib.request
from datetime import datetime, timedelta, timezone
base, token = sys.argv[1], sys.argv[2]
def post(path, payload):
    req = urllib.request.Request(base + path, data=json.dumps(payload).encode(),
        headers={"content-type": "application/json", "authorization": "Bearer " + token})
    return json.load(urllib.request.urlopen(req))
now = datetime.now(timezone.utc)
post("/v1/sync", {"samples": [
    # high-frequency, no workout context -> short window
    {"id": "ret-hr-0001-0000-0000-000000000000", "type": "heartRate", "kind": "quantity", "value": 70,
     "unit": "count/min", "startDate": now.isoformat(), "endDate": now.isoformat()},
    # same metric, recorded during a workout -> full retention
    {"id": "ret-hr-0002-0000-0000-000000000000", "type": "heartRate", "kind": "quantity", "value": 150,
     "unit": "count/min", "startDate": now.isoformat(), "endDate": now.isoformat(), "context": "workout"},
    # low-frequency -> full retention
    {"id": "ret-bm-0001-0000-0000-000000000000", "type": "bodyMass", "kind": "quantity", "value": 75,
     "unit": "kg", "startDate": now.isoformat(), "endDate": now.isoformat()},
]})
post("/v1/sync", {"hourlyStats": [
    {"date": now.strftime("%Y-%m-%d"), "hour": 7, "type": "stepCount", "unit": "count", "sum": 820},
    {"date": now.strftime("%Y-%m-%d"), "hour": 8, "type": "stepCount", "unit": "count", "sum": 1500},
]})
print("  seeded retention + hourly fixtures")
PY2
check "hourly tool returns buckets" "1500" "$(call get_hourly_pattern '{}' | python3 -c 'import sys,json;d=json.load(sys.stdin)["days"];print(round(d[-1]["metrics"]["stepCount"]["8"]["sum"]))')"
check "hourly keeps 24 slots per metric" "2" "$(call get_hourly_pattern '{}' | python3 -c 'import sys,json;d=json.load(sys.stdin)["days"];print(len(d[-1]["metrics"]["stepCount"]))')"

echo "12. settings, history and delete"
check "default retention" "1" "$(curl -s $B/v1/settings -H "$AUTH" | python3 -c 'import sys,json;print(1 if json.load(sys.stdin)["retentionYears"] in (1,2) else 0)')"
check "retention can be set" "5" "$(curl -s -X PUT $B/v1/settings -H "$AUTH" -H 'content-type: application/json' -d '{"retentionYears":5}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["retentionYears"])')"
check "retention rejects nonsense" "422" "$(curl -s -o /dev/null -w '%{http_code}' -X PUT $B/v1/settings -H "$AUTH" -H 'content-type: application/json' -d '{"retentionYears":999}')"
curl -s -X POST $B/v1/syncs -H "$AUTH" -H 'content-type: application/json' -d '{"startedAt":"2026-10-24T03:00:00.000Z","durationMs":910,"trigger":"background","samples":120,"workouts":1,"days":2}' > /dev/null
check "sync log stored" "120" "$(curl -s $B/v1/syncs -H "$AUTH" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["samples"])')"
check "connectors listed" "0" "$(curl -s $B/v1/connectors -H "$AUTH" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))')"

echo "13. VO2 max falls back to an estimate"
# Its own user: this suite has already seeded a measured VO2 max for the main one, and the
# fallback only runs when Apple published nothing.
EST_TOKEN=t-estimate
EST_AUTH="authorization: Bearer $EST_TOKEN"
call_est() { curl -s -X POST $B/mcp -H "$EST_AUTH" -H 'content-type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["content"][0]["text"])'; }
python3 - "$B" "$EST_TOKEN" <<'PY2'
import json, sys, urllib.request
from datetime import datetime, timedelta, timezone, date
base, token = sys.argv[1], sys.argv[2]
def post(payload):
    req = urllib.request.Request(base + "/v1/sync", data=json.dumps(payload).encode(),
        headers={"content-type": "application/json", "authorization": "Bearer " + token})
    return json.load(urllib.request.urlopen(req))
start = datetime.now(timezone.utc) - timedelta(days=2)
post({"workouts": [{"id": "vo2-est-0000-0000-0000-000000000001", "activityType": 37,
    "activityTypeName": "running", "startDate": start.isoformat(),
    "endDate": (start + timedelta(minutes=40)).isoformat(), "durationSec": 2400,
    "avgHeartRate": 150, "maxHeartRate": 182}]})
post({"dailyStats": [{"date": (date.today() - timedelta(days=1)).isoformat(),
    "type": "restingHeartRate", "unit": "count/min", "avg": 52}]})
post({"profile": {"dateOfBirth": "1990-05-15", "biologicalSex": "male"}})
print("  seeded resting HR 52 and a workout peaking at 182")
PY2
CF=$(call_est get_cardio_fitness '{}')
check "marked as estimated" "estimated" "$(echo "$CF" | python3 -c 'import sys,json;print(json.load(sys.stdin)["vo2Max"]["source"])')"
check "uses the observed max" "observed in a workout" "$(echo "$CF" | python3 -c 'import sys,json;print(json.load(sys.stdin)["vo2Max"]["estimate"]["inputs"]["maxHrFrom"])')"
check "15.3 x 182/52 = 53.6" "53.6" "$(echo "$CF" | python3 -c 'import sys,json;print(json.load(sys.stdin)["vo2Max"]["current"])')"
check "accuracy is disclosed" "1" "$(echo "$CF" | grep -ci 'not comparable with an Apple')"
check "still classified" "1" "$(echo "$CF" | python3 -c 'import sys,json;c=json.load(sys.stdin)["vo2Max"]["classification"];print(1 if c and c.get("level") else 0)')"

echo "13b. retention backfill pages and resumes"
# More documents than one page, to exercise the cursor rather than a single pass.
python3 - "$B" "$TOKEN" <<'PY2'
import json, sys, urllib.request
from datetime import datetime, timedelta, timezone
base, token = sys.argv[1], sys.argv[2]
now = datetime.now(timezone.utc)
batch = []
for i in range(1200):
    t = now - timedelta(minutes=i)
    batch.append({"id": "page-%04d-0000-0000-000000000000" % i, "type": "walkingSpeed",
                  "kind": "quantity", "value": 1.2, "unit": "m/s",
                  "startDate": t.isoformat(), "endDate": t.isoformat()})
for chunk in range(0, len(batch), 600):
    req = urllib.request.Request(base + "/v1/sync",
        data=json.dumps({"samples": batch[chunk:chunk + 600]}).encode(),
        headers={"content-type": "application/json", "authorization": "Bearer " + token})
    urllib.request.urlopen(req)
print("  seeded 1200 walkingSpeed samples (page size is 1000)")
PY2
R=$(curl -s -X POST "$B/v1/retention/apply?scope=walkingSpeed" -H "$AUTH")
check "scans past the first page" "1" "$(echo "$R" | python3 -c 'import sys,json;print(1 if json.load(sys.stdin)["scanned"] > 1000 else 0)')"
check "reports completion" "True" "$(echo "$R" | python3 -c 'import sys,json;print(json.load(sys.stdin)["done"])')"
check "no cursor when done" "1" "$(echo "$R" | python3 -c 'import sys,json;print(0 if json.load(sys.stdin).get("after") else 1)')"
check "resumes from a cursor" "1" "$(curl -s -X POST "$B/v1/retention/apply?scope=walkingSpeed&after=page-0500-0000-0000-000000000000" -H "$AUTH" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(1 if 0 < d["scanned"] < 1200 else 0)')"

echo "13c. retention backfill"
check "dry run stamps nothing" "true" "$(curl -s -X POST "$B/v1/retention/apply?scope=heartRate" -H "$AUTH" | python3 -c 'import sys,json;print(str(json.load(sys.stdin)["dryRun"]).lower())')"
check "already-stamped rows are skipped" "0" "$(curl -s -X POST "$B/v1/retention/apply?scope=heartRate&dryRun=false" -H "$AUTH" | python3 -c 'import sys,json;print(json.load(sys.stdin)["stamped"])')"
check "daily scope runs" "1" "$(curl -s -X POST "$B/v1/retention/apply?scope=daily&dryRun=false" -H "$AUTH" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(1 if d["scope"]=="daily" else 0)')"

echo "14. training readiness end to end"
python3 - "$B" "$TOKEN" <<'PY2'
import json, sys, urllib.request
from datetime import date, timedelta
base, token = sys.argv[1], sys.argv[2]
stats = []
# Thirty days of steady baseline, then a day with suppressed HRV and a raised resting pulse.
for i in range(30):
    d = (date.today() - timedelta(days=29 - i)).isoformat()
    last = i == 29
    stats += [
        {"date": d, "type": "heartRateVariabilitySDNN", "unit": "ms", "avg": 40 if last else 62},
        {"date": d, "type": "restingHeartRate", "unit": "count/min", "avg": 68 if last else 60},
        {"date": d, "type": "appleExerciseTime", "unit": "min", "sum": 30},
    ]
req = urllib.request.Request(base + "/v1/sync",
    data=json.dumps({"timeZone": "Asia/Bangkok", "dailyStats": stats}).encode(),
    headers={"content-type": "application/json", "authorization": "Bearer " + token})
urllib.request.urlopen(req)
print("  seeded 30 days of baseline with a hard last day")
PY2
R=$(call get_training_readiness '{}')
SCORE=$(echo "$R" | python3 -c 'import sys,json;print(json.load(sys.stdin)["score"])')
check "scores below the ready band" "1" "$([ "$SCORE" -lt 60 ] && echo 1 || echo 0)"
check "names the band" "1" "$(echo "$R" | python3 -c 'import sys,json;print(1 if json.load(sys.stdin)["bandLabel"] else 0)')"
check "headline ends with the advice" "True" "$(echo "$R" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["headline"].endswith(d["advice"]))')"
check "reports sleep as missing" "1" "$(echo "$R" | python3 -c 'import sys,json;print(1 if "sleep" in json.load(sys.stdin)["missing"] else 0)')"
check "says the baseline is personal" "1" "$(echo "$R" | grep -ci 'ไม่ใช่ค่ามาตรฐานประชากร')"
check "REST route agrees with the tool" "$SCORE" "$(curl -s $B/v1/readiness -H "$AUTH" | python3 -c 'import sys,json;print(json.load(sys.stdin)["score"])')"

echo "15. readiness uses last night, not the oldest night in the window"
python3 - "$B" "$EST_TOKEN" <<'PY2'
import json, sys, urllib.request
from datetime import datetime, timedelta, timezone
base, token = sys.argv[1], sys.argv[2]
def post(payload):
    req = urllib.request.Request(base + "/v1/sync", data=json.dumps(payload).encode(),
        headers={"content-type": "application/json", "authorization": "Bearer " + token})
    urllib.request.urlopen(req)
now = datetime.now(timezone.utc)
def night(start, minutes, tag):
    return {"id": "sleep-%s-0000-0000-000000000000" % tag, "type": "sleepAnalysis", "kind": "category",
            "value": 3, "valueLabel": "asleepCore", "startDate": start.isoformat(),
            "endDate": (start + timedelta(minutes=minutes)).isoformat()}
# a long night two days ago, a shorter one last night, and a stub older still
post({"timeZone": "UTC", "samples": [
    night(now - timedelta(days=2, hours=8), 480, "old"),
    night(now - timedelta(hours=9), 400, "last"),
    night(now - timedelta(days=3, hours=2), 34, "frag"),
]})
print("  seeded 3 nights: 480, 400 (last night) and a 34-minute fragment")
PY2
R=$(call_est get_training_readiness '{}')
check "picks last night" "400" "$(echo "$R" | python3 -c 'import sys,json;f=[x for x in json.load(sys.stdin)["factors"] if x["key"]=="sleep"];print(f[0]["value"] if f else "none")')"
check "not the fragment" "1" "$(echo "$R" | python3 -c 'import sys,json;f=[x for x in json.load(sys.stdin)["factors"] if x["key"]=="sleep"];print(0 if f and f[0]["value"] == 34 else 1)')"

echo "16. body battery end to end"
python3 - "$B" "$EST_TOKEN" <<'PY2'
import json, sys, urllib.request
from datetime import datetime, timedelta, timezone
base, token = sys.argv[1], sys.argv[2]
now = datetime.now(timezone.utc)
today = now.date().isoformat()
# Hours of the day: a quiet morning, then a run at 09:00 that costs most of the battery.
hourly = []
for hour in range(24):
    run = hour == 9
    hourly += [
        {"date": today, "hour": hour, "type": "activeEnergyBurned", "unit": "kcal", "sum": 600 if run else 10},
        {"date": today, "hour": hour, "type": "heartRate", "unit": "count/min", "avg": 150 if run else 62},
    ]
payload = {"timeZone": "UTC", "hourlyStats": hourly,
           "dailyStats": [{"date": today, "type": "restingHeartRate", "unit": "count/min", "avg": 55}]}
req = urllib.request.Request(base + "/v1/sync", data=json.dumps(payload).encode(),
    headers={"content-type": "application/json", "authorization": "Bearer " + token})
urllib.request.urlopen(req)
print("  seeded today's hourly energy and heart rate")
PY2
R=$(call_est get_body_battery '{}')
LEVEL=$(echo "$R" | python3 -c 'import sys,json;print(json.load(sys.stdin)["level"])')
check "level is within range" "1" "$([ "$LEVEL" -ge 0 ] && [ "$LEVEL" -le 100 ] && echo 1 || echo 0)"
check "the night charged something" "1" "$(echo "$R" | python3 -c 'import sys,json;print(1 if json.load(sys.stdin)["chargedOvernight"] > 0 else 0)')"
check "the day drained something" "1" "$(echo "$R" | python3 -c 'import sys,json;print(1 if json.load(sys.stdin)["drainedToday"] > 0 else 0)')"
# The night can only add, and a level already at 100 cannot rise further — which is what this
# user's history does, since its earlier days have no hourly data to drain against.
check "the night never costs anything" "1" "$(echo "$R" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(1 if d["wakeLevel"] >= d["bedLevel"] else 0)')"
check "waking level is where the day started" "1" "$(echo "$R" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(1 if d["wakeLevel"] == d["level"] - d["sinceWake"] else 0)')"
check "the day has cost something since waking" "1" "$(echo "$R" | python3 -c 'import sys,json;print(1 if json.load(sys.stdin)["sinceWake"] < 0 else 0)')"
check "carries a coaching line" "1" "$(echo "$R" | python3 -c 'import sys,json;print(1 if json.load(sys.stdin).get("message") else 0)')"
check "says it is not Garmin" "1" "$(echo "$R" | grep -ci 'Garmin')"
check "REST route agrees with the tool" "$LEVEL" "$(curl -s $B/v1/battery -H "$EST_AUTH" | python3 -c 'import sys,json;print(json.load(sys.stdin)["level"])')"

echo "17. retention apply brings an expiry forward, never back"
# Written while retention was 5 years, then the user picks 1: the sweep has to shorten what is
# already stamped, which is the same path a metric moving to the short tier takes.
curl -s -X PUT $B/v1/settings -H "$AUTH" -H 'content-type: application/json' -d '{"retentionYears":5}' > /dev/null
python3 - "$B" "$TOKEN" <<'PY2'
import json, sys, urllib.request
from datetime import datetime, timezone
base, token = sys.argv[1], sys.argv[2]
now = datetime.now(timezone.utc).isoformat()
req = urllib.request.Request(base + "/v1/sync", data=json.dumps({"samples": [
    {"id": "ret-wc-0001-0000-0000-000000000000", "type": "waistCircumference", "kind": "quantity",
     "value": 81, "unit": "cm", "startDate": now, "endDate": now}]}).encode(),
    headers={"content-type": "application/json", "authorization": "Bearer " + token})
urllib.request.urlopen(req)
PY2
curl -s -X PUT $B/v1/settings -H "$AUTH" -H 'content-type: application/json' -d '{"retentionYears":1}' > /dev/null
R=$(curl -s -X POST "$B/v1/retention/apply?scope=waistCircumference&dryRun=false" -H "$AUTH")
check "shortens the existing expiry" "1" "$(echo "$R" | python3 -c 'import sys,json;print(json.load(sys.stdin)["stamped"])')"
R=$(curl -s -X POST "$B/v1/retention/apply?scope=waistCircumference&dryRun=false" -H "$AUTH")
check "running it again changes nothing" "0" "$(echo "$R" | python3 -c 'import sys,json;print(json.load(sys.stdin)["stamped"])')"
curl -s -X PUT $B/v1/settings -H "$AUTH" -H 'content-type: application/json' -d '{"retentionYears":5}' > /dev/null
R=$(curl -s -X POST "$B/v1/retention/apply?scope=waistCircumference&dryRun=false" -H "$AUTH")
check "widening retention does not push it back" "0" "$(echo "$R" | python3 -c 'import sys,json;print(json.load(sys.stdin)["stamped"])')"

echo "18. a rings-only sync does not erase that day's statistics"
# The app recomputes statistics only for metrics that changed, but sends activity rings for the
# whole recent window every time. That combination wiped four days of HRV, resting pulse and
# exercise minutes in production.
python3 - "$B" "$EST_TOKEN" <<'PY2'
import json, sys, urllib.request
base, token = sys.argv[1], sys.argv[2]
def post(payload):
    req = urllib.request.Request(base + "/v1/sync", data=json.dumps(payload).encode(),
        headers={"content-type": "application/json", "authorization": "Bearer " + token})
    urllib.request.urlopen(req)
post({"timeZone": "UTC", "dailyStats": [
    {"date": "2026-03-01", "type": "restingHeartRate", "unit": "count/min", "avg": 58},
    {"date": "2026-03-01", "type": "appleExerciseTime", "unit": "min", "sum": 42},
]})
post({"timeZone": "UTC", "activitySummaries": [
    {"date": "2026-03-01", "activeEnergyKcal": 700, "activeEnergyGoalKcal": 320,
     "exerciseMinutes": 42, "exerciseMinutesGoal": 30, "standHours": 11, "standHoursGoal": 10}]})
print("  synced statistics, then rings alone for the same day")
PY2
DAY=$(curl -s "$B/v1/daily?from=2026-03-01&to=2026-03-01" -H "$EST_AUTH")
check "resting pulse survives" "58" "$(echo "$DAY" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["metrics"]["restingHeartRate"]["avg"])')"
check "exercise minutes survive" "42" "$(echo "$DAY" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["metrics"]["appleExerciseTime"]["sum"])')"
check "the rings landed too" "700" "$(echo "$DAY" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["activity"]["activeEnergyKcal"])')"

echo "19. readiness is computed once a day and then frozen"
R1=$(curl -s $B/v1/readiness -H "$AUTH")
check "locked once the measured factors are in" "True" "$(echo "$R1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["locked"])')"
check "carries the time it was computed" "1" "$(echo "$R1" | python3 -c 'import sys,json;print(1 if json.load(sys.stdin).get("computedAt") else 0)')"
STAMP=$(echo "$R1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["computedAt"])')
# New data landing later must not move today's score.
python3 - "$B" "$TOKEN" <<'PY2'
import json, sys, urllib.request
from datetime import date
base, token = sys.argv[1], sys.argv[2]
req = urllib.request.Request(base + "/v1/sync",
    data=json.dumps({"dailyStats": [
        {"date": date.today().isoformat(), "type": "heartRateVariabilitySDNN", "unit": "ms", "avg": 120},
        {"date": date.today().isoformat(), "type": "restingHeartRate", "unit": "count/min", "avg": 48}]}).encode(),
    headers={"content-type": "application/json", "authorization": "Bearer " + token})
urllib.request.urlopen(req)
print("  synced a much better HRV and pulse after the score was frozen")
PY2
R2=$(curl -s $B/v1/readiness -H "$AUTH")
check "the score does not move" "$(echo "$R1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["score"])')" "$(echo "$R2" | python3 -c 'import sys,json;print(json.load(sys.stdin)["score"])')"
check "nor the time it was computed" "$STAMP" "$(echo "$R2" | python3 -c 'import sys,json;print(json.load(sys.stdin)["computedAt"])')"
check "the tool agrees with the route" "$(echo "$R2" | python3 -c 'import sys,json;print(json.load(sys.stdin)["score"])')" "$(call get_training_readiness '{}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["score"])')"

echo "20. a nap does not get counted as part of the night"
# Fixed dates: the result must not depend on what time of day the suite runs.
python3 - "$B" "$EST_TOKEN" <<'PY2'
import json, sys, urllib.request
base, token = sys.argv[1], sys.argv[2]
def sample(tag, start, end, label="asleepCore", value=3, source="Watch"):
    return {"id": "nap-%s-0000-0000-000000000000" % tag, "type": "sleepAnalysis", "kind": "category",
            "value": value, "valueLabel": label, "sourceName": source,
            "startDate": start, "endDate": end}
payload = {"timeZone": "UTC", "samples": [
    # A night from 23:20 to 06:00, with an hour awake in the middle: two stretches, one night.
    sample("n1", "2026-02-09T23:20:00.000Z", "2026-02-10T02:00:00.000Z"),
    sample("n2", "2026-02-10T03:10:00.000Z", "2026-02-10T06:00:00.000Z"),
    # The phone recorded the same night: the same minutes must not be counted twice.
    sample("n3", "2026-02-09T23:20:00.000Z", "2026-02-10T02:00:00.000Z", source="iPhone"),
    # And a nap in the afternoon of the same date.
    sample("p1", "2026-02-10T14:00:00.000Z", "2026-02-10T14:45:00.000Z"),
]}
req = urllib.request.Request(base + "/v1/sync", data=json.dumps(payload).encode(),
    headers={"content-type": "application/json", "authorization": "Bearer " + token})
urllib.request.urlopen(req)
print("  seeded a split night (160 + 170 min), a duplicate from a second source, and a 45-minute nap")
PY2
S=$(call_est get_sleep '{"from":"2026-02-10","to":"2026-02-10"}')
check "both halves of the night are one night" "330" "$(echo "$S" | python3 -c 'import sys,json;n=json.load(sys.stdin)["nights"];print(n[0]["asleepMinutes"] if n else 0)')"
check "the second source does not double it" "1" "$(echo "$S" | python3 -c 'import sys,json;n=json.load(sys.stdin)["nights"];print(1 if n and n[0]["asleepMinutes"] < 400 else 0)')"
check "the nap is kept separate" "45" "$(echo "$S" | python3 -c 'import sys,json;n=json.load(sys.stdin)["nights"];print(sum(p["asleepMinutes"] for x in n for p in x.get("naps",[])))')"
check "the sleep window is reported" "1" "$(echo "$S" | python3 -c 'import sys,json;n=json.load(sys.stdin)["nights"];print(1 if n and n[0].get("sleepWindowMinutes") else 0)')"
check "but time in bed is not invented" "1" "$(echo "$S" | python3 -c '
import sys, json
n = json.load(sys.stdin)["nights"][0]
# No inBed stage was recorded for this fixture, so none may be reported.
print(1 if "inBedMinutes" not in n and "inBed" not in n.get("stagesMinutes", {}) else 0)')"
check "waking is the morning, not the nap" "06" "$(echo "$S" | python3 -c 'import sys,json;n=json.load(sys.stdin)["nights"];print(n[0]["wakeTime"][11:13] if n else "")')"

echo "21. splits come back with the workout detail"
WID=$(call_est get_workouts '{"days":30,"limit":1}' | python3 -c 'import sys,json;w=json.load(sys.stdin)["workouts"];print(w[0]["id"] if w else "")')
if [ -n "$WID" ]; then
  D=$(call_est get_workout_detail "{\"workoutId\":\"$WID\"}")
  check "the detail carries a splits field" "1" "$(echo "$D" | python3 -c 'import sys,json;print(1 if "splits" in json.load(sys.stdin) else 0)')"
  check "and says why when there are none" "1" "$(echo "$D" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(1 if d["splits"] or "No splits" in d["note"] else 0)')"
else
  echo "  skipped: no workout seeded for this user"
fi

echo "22. a day with nothing recorded counts as zero, not as missing"
python3 - "$B" "$EST_TOKEN" <<'PY2'
import json, sys, urllib.request
base, token = sys.argv[1], sys.argv[2]
# Four days in a ten-day window carry exercise; the other six carry nothing at all.
stats = [{"date": d, "type": "appleExerciseTime", "unit": "min", "sum": 60}
         for d in ("2026-04-02", "2026-04-04", "2026-04-06", "2026-04-08")]
req = urllib.request.Request(base + "/v1/sync", data=json.dumps({"timeZone": "UTC", "dailyStats": stats}).encode(),
    headers={"content-type": "application/json", "authorization": "Bearer " + token})
urllib.request.urlopen(req)
print("  seeded 4 days of 60 minutes inside a 10-day window")
PY2
M=$(call_est get_metric_stats '{"types":["appleExerciseTime"],"from":"2026-04-01","to":"2026-04-10"}')
check "averages over recorded days as before" "60" "$(echo "$M" | python3 -c 'import sys,json;print(round(json.load(sys.stdin)["metrics"]["appleExerciseTime"]["avg"]))')"
check "and over every day in the range too" "24" "$(echo "$M" | python3 -c 'import sys,json;print(round(json.load(sys.stdin)["metrics"]["appleExerciseTime"]["avgPerDayInRange"]))')"
check "says how many days carry a reading" "4" "$(echo "$M" | python3 -c 'import sys,json;print(json.load(sys.stdin)["metrics"]["appleExerciseTime"]["days"])')"
check "and how many the range covers" "10" "$(echo "$M" | python3 -c 'import sys,json;print(json.load(sys.stdin)["daysInRange"])')"
check "a discrete metric gets no per-day figure" "1" "$(call_est get_metric_stats '{"types":["restingHeartRate"],"from":"2026-04-01","to":"2026-04-10"}' | python3 -c 'import sys,json;print(0 if "avgPerDayInRange" in json.load(sys.stdin)["metrics"]["restingHeartRate"] else 1)')"

echo "23. heart-rate zones come from the rate actually recorded"
C=$(call_est get_cardio_fitness '{}')
check "reports a maximum" "1" "$(echo "$C" | python3 -c 'import sys,json;print(1 if json.load(sys.stdin)["heartRate"]["max"] else 0)')"
check "says where it came from" "1" "$(echo "$C" | python3 -c 'import sys,json;print(1 if json.load(sys.stdin)["heartRate"]["source"] in ("measured","estimated") else 0)')"
check "five zones, ending at the maximum" "1" "$(echo "$C" | python3 -c '
import sys, json
h = json.load(sys.stdin)["heartRate"]
print(1 if len(h["zones"]) == 5 and h["zones"][-1]["to"] == h["max"] else 0)')"
check "zones rise without gaps" "1" "$(echo "$C" | python3 -c '
import sys, json
z = json.load(sys.stdin)["heartRate"]["zones"]
print(1 if all(z[i]["to"] == z[i+1]["from"] for i in range(len(z)-1)) else 0)')"

echo "24. times carry the user's own clock, not just UTC"
S=$(call_est get_sleep '{"from":"2026-02-10","to":"2026-02-10"}')
check "sleep carries a local reading" "1" "$(echo "$S" | python3 -c 'import sys,json;n=json.load(sys.stdin)["nights"];print(1 if n and n[0].get("wakeTimeLocal") else 0)')"
# This user is on UTC, so both readings of the same instant must agree.
check "and it matches the UTC stamp" "same" "$(echo "$S" | python3 -c '
import sys, json
n = json.load(sys.stdin)["nights"][0]
local = n["wakeTimeLocal"]
utc = n["wakeTime"][:10] + " " + n["wakeTime"][11:16]
print("same" if local == utc else local + " vs " + utc)')"
check "workouts carry one as well" "1" "$(call_est get_workouts '{"days":365,"limit":1}' | python3 -c 'import sys,json;w=json.load(sys.stdin)["workouts"];print(1 if w and w[0].get("startLocal") else 0)')"

echo "25. sleeping HRV is a median over several nights, not one noisy reading"
python3 - "$B" "$EST_TOKEN" <<'PY2'
import json, sys, urllib.request
from datetime import datetime, timedelta, timezone
base, token = sys.argv[1], sys.argv[2]
now = datetime.now(timezone.utc).replace(microsecond=0)
samples = []
# Twenty nights, each with three readings around 60 ms — and one reading a night that spikes,
# the way a wrist sensor does. A mean would follow the spikes; a median should not.
for night in range(20):
    end = (now - timedelta(days=night)).replace(hour=6, minute=0, second=0)
    start = end - timedelta(hours=7)
    samples.append({"id": "hrvsleep-%02d-0000-0000-00000000000a" % night, "type": "sleepAnalysis",
                    "kind": "category", "value": 3, "valueLabel": "asleepCore",
                    "startDate": start.isoformat(), "endDate": end.isoformat()})
    for i, value in enumerate((58, 60, 200)):
        at = start + timedelta(hours=i + 1)
        samples.append({"id": "hrvval-%02d-%d-0000-00000000000b" % (night, i), "type": "heartRateVariabilitySDNN",
                        "kind": "quantity", "value": value, "unit": "ms",
                        "startDate": at.isoformat(), "endDate": at.isoformat()})
req = urllib.request.Request(base + "/v1/sync", data=json.dumps({"timeZone": "UTC", "samples": samples}).encode(),
    headers={"content-type": "application/json", "authorization": "Bearer " + token})
urllib.request.urlopen(req)
print("  seeded 20 nights of 58/60/200 ms readings")
PY2
R=$(call_est get_training_readiness '{}')
check "switches to the sleeping figure" "sleep" "$(echo "$R" | python3 -c 'import sys,json;f=[x for x in json.load(sys.stdin)["factors"] if x["key"]=="hrv"];print(f[0].get("source") if f else "none")')"
check "the spike does not set the night" "60" "$(echo "$R" | python3 -c 'import sys,json;f=[x for x in json.load(sys.stdin)["factors"] if x["key"]=="hrv"];print(round(f[0]["value"]) if f else 0)')"
check "nor the baseline" "60" "$(echo "$R" | python3 -c 'import sys,json;f=[x for x in json.load(sys.stdin)["factors"] if x["key"]=="hrv"];print(round(f[0]["baseline"]) if f else 0)')"
check "says how it was worked out" "1" "$(echo "$R" | python3 -c 'import sys,json;f=[x for x in json.load(sys.stdin)["factors"] if x["key"]=="hrv"];print(1 if "คืน" in (f[0].get("note") or "") else 0)')"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
