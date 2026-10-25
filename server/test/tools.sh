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
check "tool count" "12" "$(curl -s -X POST $B/mcp -H "$AUTH" -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["result"]["tools"]))')"

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

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
