#!/bin/bash
# Verifies: weather normalisation, daily fallback for latest values, workout detail series.
set -uo pipefail
B=${B:-http://localhost:3030}
AUTH="authorization: Bearer $TOKEN"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1: expected [$2] got [$3]"; fail=$((fail+1)); fi; }
call() { curl -s -X POST $B/mcp -H "$AUTH" -H 'content-type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["content"][0]["text"])'; }

echo "0. seed (run with weather, HR during + after, speed, old weigh-in)"
WID=$(python3 - "$B" "$TOKEN" <<'PY'
import json, sys, urllib.request
from datetime import datetime, timedelta, timezone, date
base, token = sys.argv[1], sys.argv[2]
def post(payload):
    req = urllib.request.Request(base + "/v1/sync", data=json.dumps(payload).encode(),
        headers={"content-type": "application/json", "authorization": "Bearer " + token})
    return json.load(urllib.request.urlopen(req))
start = datetime.now(timezone.utc) - timedelta(hours=3)
end = start + timedelta(minutes=50)
wid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
post({"timeZone": "Asia/Bangkok", "workouts": [{
    "id": wid, "activityType": 37, "activityTypeName": "running",
    "startDate": start.isoformat(), "endDate": end.isoformat(), "durationSec": 3000,
    "activeEnergyKcal": 450, "distanceM": 8000, "avgHeartRate": 152, "minHeartRate": 95,
    "maxHeartRate": 178, "isIndoor": False,
    # exactly the shape HealthKit produces
    "metadata": {"HKWeatherTemperature": "78.26 degF", "HKWeatherHumidity": "9000 %", "HKTimeZone": "Asia/Bangkok"}}]})
# HR every 30s during the run, then a recovery tail that drops
samples = []
for i in range(100):
    t = start + timedelta(seconds=30 * i)
    samples.append({"id": f"hr-{i:04d}-0000-0000-0000-00000000", "type": "heartRate", "kind": "quantity",
                    "value": 140 + (i % 20), "unit": "count/min", "startDate": t.isoformat(), "endDate": t.isoformat()})
for i in range(10):  # 5 minutes of recovery, dropping fast
    t = end + timedelta(seconds=30 * i)
    samples.append({"id": f"rec-{i:04d}-0000-0000-0000-00000000", "type": "heartRate", "kind": "quantity",
                    "value": 170 - i * 8, "unit": "count/min", "startDate": t.isoformat(), "endDate": t.isoformat()})
for i in range(60):
    t = start + timedelta(seconds=50 * i)
    samples.append({"id": f"spd-{i:04d}-0000-0000-0000-00000000", "type": "runningSpeed", "kind": "quantity",
                    "value": 2.6 + (i % 5) * 0.1, "unit": "m/s", "startDate": t.isoformat(), "endDate": t.isoformat()})
# HR sample well outside the window, must not leak in
far = start - timedelta(days=2)
samples.append({"id": "far-0000-0000-0000-000000000000", "type": "heartRate", "kind": "quantity",
                "value": 60, "unit": "count/min", "startDate": far.isoformat(), "endDate": far.isoformat()})
post({"samples": samples})
# weight/fat only as daily aggregates, 20 days ago -> outside any raw window
d = (date.today() - timedelta(days=20)).isoformat()
post({"dailyStats": [
    {"date": d, "type": "bodyMass", "unit": "kg", "avg": 75.3, "min": 75.3, "max": 75.3},
    {"date": d, "type": "bodyFatPercentage", "unit": "%", "avg": 0.182, "min": 0.182, "max": 0.182},
]})
print(wid)
PY
)
echo "  workout id: $WID"

echo "1. weather normalised"
W=$(curl -s "$B/v1/workouts?from=$(date -u -v-1d +%Y-%m-%d)&to=$(date -u -v+1d +%Y-%m-%d)&limit=5" -H "$AUTH")
check "78.26 degF -> 25.7 C" "25.7" "$(echo "$W" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["weatherTempC"])')"
check "9000 % -> 90 %" "90" "$(echo "$W" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["weatherHumidityPercent"])')"
check "raw metadata kept" "78.26 degF" "$(echo "$W" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["metadata"]["HKWeatherTemperature"])')"

echo "2. latest values fall back to daily"
LV=$(call get_latest_values '{"types":["bodyMass","bodyFatPercentage","heartRate"]}')
check "weight found" "75.3" "$(echo "$LV" | python3 -c 'import sys,json;print([v["value"] for v in json.load(sys.stdin)["values"] if v["type"]=="bodyMass"][0])')"
check "weight marked as daily" "daily" "$(echo "$LV" | python3 -c 'import sys,json;print([v["from"] for v in json.load(sys.stdin)["values"] if v["type"]=="bodyMass"][0])')"
check "body fat found" "0.182" "$(echo "$LV" | python3 -c 'import sys,json;print([v["value"] for v in json.load(sys.stdin)["values"] if v["type"]=="bodyFatPercentage"][0])')"
check "heart rate still from sample" "sample" "$(echo "$LV" | python3 -c 'import sys,json;print([v["from"] for v in json.load(sys.stdin)["values"] if v["type"]=="heartRate"][0])')"

echo "3. workout detail"
WD=$(call get_workout_detail "{\"workoutId\":\"$WID\"}")
check "hr samples in window" "110" "$(echo "$WD" | python3 -c 'import sys,json;print(json.load(sys.stdin)["heartRate"]["count"])')"
check "speed samples" "60" "$(echo "$WD" | python3 -c 'import sys,json;print(json.load(sys.stdin)["speed"]["count"])')"
check "series is oldest-first" "True" "$(echo "$WD" | python3 -c 'import sys,json;s=json.load(sys.stdin)["heartRate"]["series"];print(s[0]["at"] < s[-1]["at"])')"
check "recovery tail included" "98" "$(echo "$WD" | python3 -c 'import sys,json;print(json.load(sys.stdin)["heartRate"]["series"][-1]["value"])')"
check "weather on the workout" "25.7" "$(echo "$WD" | python3 -c 'import sys,json;print(json.load(sys.stdin)["workout"]["weatherTempC"])')"
check "out-of-window sample excluded" "0" "$(echo "$WD" | python3 -c 'import sys,json;print(sum(1 for p in json.load(sys.stdin)["heartRate"]["series"] if p["value"]==60))')"
ARGS2='{"workoutId":"'"$WID"'","recoveryMinutes":2}'
WD2=$(call get_workout_detail "$ARGS2")
check "recoveryMinutes respected" "2" "$(echo "$WD2" | python3 -c 'import sys,json;print(json.load(sys.stdin)["window"]["recoveryMinutes"])')"
check "shorter tail trims samples" "104" "$(echo "$WD2" | python3 -c 'import sys,json;print(json.load(sys.stdin)["heartRate"]["count"])')"
check "unknown id rejected" "1" "$(call get_workout_detail '{"workoutId":"00000000-0000-0000-0000-000000000000"}' | grep -ci 'No workout with id')"
check "missing id rejected" "1" "$(call get_workout_detail '{}' | grep -ci 'required')"

echo "4. nothing regressed"
check "tool count" "13" "$(curl -s -X POST $B/mcp -H "$AUTH" -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["result"]["tools"]))')"
check "get_workouts still works" "1" "$(call get_workouts '{}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["count"])')"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
