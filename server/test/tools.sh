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
check "tool count" "10" "$(curl -s -X POST $B/mcp -H "$AUTH" -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["result"]["tools"]))')"

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
check "unknown metric is null" "None" "$(call get_metric_stats '{"types":["nothingHere"]}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["metrics"]["nothingHere"])')"
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

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
