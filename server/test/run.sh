#!/bin/bash
# End-to-end tests against a local server + Firestore emulator. Nothing here touches production.
#
#   bun install
#   test/run.sh            # starts the emulator, the server, runs every suite, cleans up
#
# Needs: bun, java for the emulator, python3, curl, and the Firebase CLI — an installed `firebase`
# is used when there is one, since fetching the package on every run was the only part of this
# that could hang, and a hung fetch looks exactly like a hung test run.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
TMP=$(mktemp -d)
export B=http://localhost:3030
# npx spawns the emulator's JVM as a grandchild, which outlives the shell's job list and keeps
# port 8080, so it is matched by name. Only Firestore emulator processes are touched.
cleanup() {
  kill $(jobs -p) 2>/dev/null
  pkill -f cloud-firestore-emulator 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

if lsof -nP -iTCP:8080 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port 8080 is already in use — stop the other Firestore emulator first" >&2
  exit 1
fi

# The emulator enforces firestore.rules, which deny everything, so the suites run against an
# open-rules copy. Production rules are unchanged.
mkdir -p "$TMP/emu"
cat > "$TMP/emu/firebase.json" <<'JSON'
{ "firestore": { "rules": "open.rules" }, "emulators": { "firestore": { "port": 8080 }, "ui": { "enabled": false } } }
JSON
cat > "$TMP/emu/open.rules" <<'RULES'
rules_version = '2';
service cloud.firestore {
  match /databases/{db}/documents { match /{document=**} { allow read, write: if true; } }
}
RULES

# The Firestore REST client wants credentials even against the emulator, so a throwaway key and a
# stub token endpoint stand in. The emulator ignores the token itself.
openssl genrsa -out "$TMP/key.pem" 2048 2>/dev/null
python3 - "$TMP" <<'PY'
import json, sys
tmp = sys.argv[1]
json.dump({"type": "service_account", "project_id": "proxy-health-data", "private_key_id": "test",
           "private_key": open(f"{tmp}/key.pem").read(),
           "client_email": "test@proxy-health-data.iam.gserviceaccount.com", "client_id": "0",
           "token_uri": "http://localhost:3031/token"}, open(f"{tmp}/sa.json", "w"))
PY
python3 - <<'PY' &
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length', 0)))
        body = json.dumps({"access_token": "owner", "expires_in": 3600, "token_type": "Bearer"}).encode()
        self.send_response(200); self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
HTTPServer(('127.0.0.1', 3031), H).serve_forever()
PY

# The emulator is a JVM program, and the Firebase CLI finds the JVM through JAVA_HOME rather
# than the path: without it macOS answers with its /usr/bin/java stub, which exists and then
# refuses to run ("Unable to locate a Java Runtime").
if [ -z "${JAVA_HOME:-}" ] || [ ! -x "${JAVA_HOME:-}/bin/java" ]; then
  # Newest first: current firebase-tools refuses to start on anything before JDK 21.
  for jdk in /opt/homebrew/opt/openjdk /opt/homebrew/opt/openjdk@23 /opt/homebrew/opt/openjdk@21 /opt/homebrew/opt/openjdk@17; do
    [ -x "$jdk/bin/java" ] && export JAVA_HOME="$jdk" && export PATH="$jdk/bin:$PATH" && break
  done
fi
"${JAVA_HOME:-}/bin/java" -version > /dev/null 2>&1 || java -version > /dev/null 2>&1 || {
  echo "no working java — the Firestore emulator needs JDK 21 or newer (brew install openjdk)" >&2
  exit 1
}

FIREBASE=$(command -v firebase || echo "bunx firebase-tools@13.35.1")
(cd "$TMP/emu" && $FIREBASE emulators:start --only firestore --project proxy-health-data > "$TMP/emu.log" 2>&1) &
echo "waiting for the Firestore emulator…"
until grep -q "All emulators ready" "$TMP/emu.log" 2>/dev/null; do
  grep -qi "error" "$TMP/emu.log" && { tail -5 "$TMP/emu.log"; exit 1; }
  sleep 2
done

# One token per suite, so data seeded by one cannot be seen by another.
FIRESTORE_EMULATOR_HOST=localhost:8080 FIREBASE_SERVICE_ACCOUNT="$(cat "$TMP/sa.json")" \
  API_TOKENS=t-oauth:u-oauth,t-tools:u-tools,t-workout:u-workout,t-estimate:u-estimate PORT=3030 \
  bun src/index.ts > "$TMP/server.log" 2>&1 &
until curl -sf -o /dev/null $B/health; do sleep 1; done

fail=0
for pair in oauth:t-oauth tools:t-tools workout-and-latest:t-workout; do
  suite=${pair%%:*}
  echo; echo "### $suite"
  TOKEN=${pair##*:} bash "$ROOT/test/$suite.sh" || fail=1
done
exit $fail
