#!/bin/sh
# Assumes nginx/icap/backend are already running (e.g. via
# docker/docker-compose.yml) — this only drives HTTP traffic through $NGINX_URL.
set -u

BASE="${NGINX_URL:-http://localhost:8080}"
EICAR='X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'

PASS=0; FAIL=0
check() { # desc expected_substr actual
  if echo "$3" | grep -q "$2"; then echo "  PASS: $1"; PASS=$((PASS+1));
  else echo "  FAIL: $1 (got: $(echo "$3" | head -1))"; FAIL=$((FAIL+1)); fi
}

echo "== target: $BASE =="

echo
echo "== TEST 1: REQMOD goodware — clean upload should reach backend (200) =="
OUT=$(curl -s -w '\nHTTP:%{http_code}' -X POST --data-binary "this is a clean file" "$BASE/up")
echo "$OUT"
check "REQMOD clean upload passes" "backend-ok" "$OUT"
check "REQMOD clean upload HTTP 200" "HTTP:200" "$OUT"

echo
echo "== TEST 2: REQMOD malicious — EICAR upload should be BLOCKED (403) =="
OUT=$(curl -s -w '\nHTTP:%{http_code}' -X POST --data-binary "$EICAR" "$BASE/up")
echo "$OUT"
check "REQMOD malicious upload blocked" "HTTP:403" "$OUT"

echo
# Requires clean.txt / eicar to exist in the backend's SAMPLES_FOLDER mount.
echo "== TEST 3: RESPMOD goodware — clean download should pass (200) =="
OUT=$(curl -s -w '\nHTTP:%{http_code}' "$BASE/clean.txt")
echo "$OUT"
check "RESPMOD clean download passes" "HTTP:200" "$OUT"

echo
echo "== TEST 4: RESPMOD malicious — EICAR download should be BLOCKED (403) =="
OUT=$(curl -s -w '\nHTTP:%{http_code}' "$BASE/eicar")
echo "$OUT"
check "RESPMOD malicious download blocked" "HTTP:403" "$OUT"

echo
echo "================  $PASS passed, $FAIL failed  ================"
exit $FAIL