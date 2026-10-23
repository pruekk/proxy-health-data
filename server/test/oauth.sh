#!/bin/bash
# End-to-end OAuth test against a local server + Firestore emulator.
set -uo pipefail
B=${B:-http://localhost:3030}
AUTH="authorization: Bearer $TOKEN"
pass=0; fail=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  ok   $1"; pass=$((pass+1));
  else echo "  FAIL $1: expected [$2] got [$3]"; fail=$((fail+1)); fi
}

echo "1. discovery"
check "protected-resource/mcp resource" "$B/mcp" "$(curl -s $B/.well-known/oauth-protected-resource/mcp | python3 -c 'import sys,json;print(json.load(sys.stdin)["resource"])')"
check "AS issuer" "$B" "$(curl -s $B/.well-known/oauth-authorization-server | python3 -c 'import sys,json;print(json.load(sys.stdin)["issuer"])')"
check "PKCE advertised" "S256" "$(curl -s $B/.well-known/oauth-authorization-server | python3 -c 'import sys,json;print(json.load(sys.stdin)["code_challenge_methods_supported"][0])')"
check "unauth /mcp" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/mcp -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
check "www-authenticate points at metadata" "1" "$(curl -s -D - -o /dev/null -X POST $B/mcp -H 'content-type: application/json' -d '{}' | grep -ci 'resource_metadata=')"

echo "2. registration"
REG=$(curl -s -X POST $B/oauth/register -H 'content-type: application/json' \
  -d '{"client_name":"Claude","redirect_uris":["https://claude.ai/api/mcp/auth_callback"]}')
CID=$(echo "$REG" | python3 -c 'import sys,json;print(json.load(sys.stdin)["client_id"])')
check "client_id issued" "1" "$([ -n "$CID" ] && echo 1 || echo 0)"
check "no redirect_uris -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/oauth/register -H 'content-type: application/json' -d '{}')"

echo "3. authorize"
VERIFIER=$(python3 -c 'import secrets;print(secrets.token_urlsafe(48))')
CHAL=$(python3 -c "import hashlib,base64,sys;print(base64.urlsafe_b64encode(hashlib.sha256('$VERIFIER'.encode()).digest()).rstrip(b'=').decode())")
RU=https://claude.ai/api/mcp/auth_callback
Q="response_type=code&client_id=$CID&redirect_uri=$RU&code_challenge=$CHAL&code_challenge_method=S256&state=xyz&scope=health.read"
check "sign-in page" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$B/oauth/authorize?$Q")"
check "unknown client rejected" "400" "$(curl -s -o /dev/null -w '%{http_code}' "$B/oauth/authorize?response_type=code&client_id=nope&redirect_uri=$RU&code_challenge=$CHAL&code_challenge_method=S256")"
check "bad redirect_uri rejected" "400" "$(curl -s -o /dev/null -w '%{http_code}' "$B/oauth/authorize?response_type=code&client_id=$CID&redirect_uri=https://evil.example/cb&code_challenge=$CHAL&code_challenge_method=S256")"
check "missing PKCE redirects with error" "1" "$(curl -s -D - -o /dev/null "$B/oauth/authorize?response_type=code&client_id=$CID&redirect_uri=$RU&state=xyz" | grep -ci 'location:.*error=invalid_request')"
check "wrong token re-renders form" "1" "$(curl -s -X POST $B/oauth/authorize -d "response_type=code&client_id=$CID&redirect_uri=$RU&code_challenge=$CHAL&code_challenge_method=S256&state=xyz&token=wrong" | grep -ci 'not valid for this server')"

LOC=$(curl -s -D - -o /dev/null -X POST $B/oauth/authorize \
  -d "response_type=code&client_id=$CID&redirect_uri=$RU&code_challenge=$CHAL&code_challenge_method=S256&state=xyz&token=$TOKEN" | grep -i '^location:' | tr -d '\r')
CODE=$(echo "$LOC" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')
check "code issued" "1" "$([ -n "$CODE" ] && echo 1 || echo 0)"
check "state preserved" "1" "$(echo "$LOC" | grep -c 'state=xyz')"

echo "4. token exchange"
check "wrong verifier rejected" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/oauth/token -d "grant_type=authorization_code&code=$CODE&client_id=$CID&redirect_uri=$RU&code_verifier=bogus")"
# that attempt consumed the code; get a fresh one
LOC=$(curl -s -D - -o /dev/null -X POST $B/oauth/authorize \
  -d "response_type=code&client_id=$CID&redirect_uri=$RU&code_challenge=$CHAL&code_challenge_method=S256&state=xyz&token=$TOKEN" | grep -i '^location:' | tr -d '\r')
CODE=$(echo "$LOC" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')
TOK=$(curl -s -X POST $B/oauth/token -d "grant_type=authorization_code&code=$CODE&client_id=$CID&redirect_uri=$RU&code_verifier=$VERIFIER")
AT=$(echo "$TOK" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
RT=$(echo "$TOK" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("refresh_token",""))')
check "access_token issued" "1" "$([ -n "$AT" ] && echo 1 || echo 0)"
check "code is single-use" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/oauth/token -d "grant_type=authorization_code&code=$CODE&client_id=$CID&redirect_uri=$RU&code_verifier=$VERIFIER")"

echo "5. using the token"
check "tools/list with OAuth token" "10" "$(curl -s -X POST $B/mcp -H "authorization: Bearer $AT" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["result"]["tools"]))')"
check "tools/call with OAuth token" "200" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/mcp -H "authorization: Bearer $AT" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_metrics","arguments":{}}}')"
check "static token still works" "200" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/mcp -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":3,"method":"tools/list"}')"
check "REST still works" "200" "$(curl -s -o /dev/null -w '%{http_code}' $B/v1/me -H "authorization: Bearer $TOKEN")"
check "garbage token rejected" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/mcp -H 'authorization: Bearer nope' -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":4,"method":"tools/list"}')"

echo "6. refresh"
NEW=$(curl -s -X POST $B/oauth/token -d "grant_type=refresh_token&refresh_token=$RT&client_id=$CID")
AT2=$(echo "$NEW" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
check "refreshed access_token" "1" "$([ -n "$AT2" ] && [ "$AT2" != "$AT" ] && echo 1 || echo 0)"
check "refreshed token works" "200" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/mcp -H "authorization: Bearer $AT2" -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":5,"method":"tools/list"}')"
check "old refresh token rotated out" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/oauth/token -d "grant_type=refresh_token&refresh_token=$RT&client_id=$CID")"

echo "7. revocation"
check "revoke endpoint advertised" "1" "$(curl -s $B/.well-known/oauth-authorization-server | grep -c 'revocation_endpoint')"
check "revoke answers 200" "200" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/oauth/revoke -d "token=$AT2")"
check "revoked token rejected" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/mcp -H "authorization: Bearer $AT2" -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
check "unknown token still 200" "200" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/oauth/revoke -d 'token=never-existed')"
check "static token unaffected" "200" "$(curl -s -o /dev/null -w '%{http_code}' $B/v1/me -H "$AUTH")"
check "sign out everywhere" "200" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/v1/revoke-connectors -H "$AUTH")"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
