#!/usr/bin/env bash
# Smoke test for coolify-deploy.sh using a stubbed curl.
#
# The stub mimics curl's -o <file> (body) + -w '%{http_code}' (stdout) contract.
# Behaviour is driven by env vars so each test can script the API:
#   STUB_TRIGGER_HTTP   status code for POST /api/v1/deploy        (default 200)
#   STUB_TRIGGER_BODY   body for POST /api/v1/deploy               (default deployment_uuid json)
#   STUB_STATUS_HTTP    status code for GET /api/v1/deployments/*  (default 200)
#   STUB_STATUS_BODY    body for GET /api/v1/deployments/*         (default finished)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

make_stub_curl() {
  cat > "$HERE/curl" <<'EOF'
#!/usr/bin/env bash
out_file=""
fmt=""
method="GET"
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out_file="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    *) url="$1"; shift ;;
  esac
done
if [ "$method" = "POST" ]; then
  body="${STUB_TRIGGER_BODY}"
  [ -n "$body" ] || body='{"message":"Deployment request queued.","deployment_uuid":"dep123"}'
  [ -n "$out_file" ] && printf '%s' "$body" > "$out_file"
  [ -n "$fmt" ] && echo "${STUB_TRIGGER_HTTP:-200}"
else
  body="${STUB_STATUS_BODY}"
  [ -n "$body" ] || body='{"status":"finished"}'
  [ -n "$out_file" ] && printf '%s' "$body" > "$out_file"
  [ -n "$fmt" ] && echo "${STUB_STATUS_HTTP:-200}"
fi
exit 0
EOF
  chmod +x "$HERE/curl"
}

run_test() {
  local name="$1"; shift
  local expected_exit="$1"; shift
  echo -n "  $name ... "
  if "$@" > /tmp/out 2>&1; then
    actual_exit=0
  else
    actual_exit=$?
  fi
  if [ "$actual_exit" = "$expected_exit" ]; then
    echo "OK"
  else
    echo "FAIL (expected exit $expected_exit, got $actual_exit)"
    cat /tmp/out
    return 1
  fi
}

export PATH="$HERE:$PATH"

# Test 1: no uuid -> exit 2
make_stub_curl
run_test "no uuid argument" 2 env COOLIFY_API_URL=https://x.example COOLIFY_API_TOKEN=t bash "$HERE/coolify-deploy.sh"

# Test 2: missing token -> exit 3
make_stub_curl
run_test "missing token" 3 env COOLIFY_API_URL=https://x.example COOLIFY_API_TOKEN= bash "$HERE/coolify-deploy.sh" abc123

# Test 3: trigger 200 + poll finished -> exit 0
make_stub_curl
run_test "deploy finishes" 0 env COOLIFY_API_URL=https://x.example COOLIFY_API_TOKEN=t POLL_INTERVAL=0 bash "$HERE/coolify-deploy.sh" abc123

# Test 4: trigger non-200 -> exit 4
make_stub_curl
run_test "trigger fails" 4 env COOLIFY_API_URL=https://x.example COOLIFY_API_TOKEN=t STUB_TRIGGER_HTTP=500 bash "$HERE/coolify-deploy.sh" abc123

# Test 5: poll returns failed -> exit 4
make_stub_curl
run_test "deployment fails" 4 env COOLIFY_API_URL=https://x.example COOLIFY_API_TOKEN=t POLL_INTERVAL=0 STUB_STATUS_BODY='{"status":"failed"}' bash "$HERE/coolify-deploy.sh" abc123

# Test 6: poll returns cancelled -> exit 4
make_stub_curl
run_test "deployment cancelled" 4 env COOLIFY_API_URL=https://x.example COOLIFY_API_TOKEN=t POLL_INTERVAL=0 STUB_STATUS_BODY='{"status":"cancelled"}' bash "$HERE/coolify-deploy.sh" abc123

# Test 7: poll times out -> exit 5
make_stub_curl
run_test "deploy wait times out" 5 env COOLIFY_API_URL=https://x.example COOLIFY_API_TOKEN=t POLL_INTERVAL=0 DEPLOY_TIMEOUT=0 STUB_STATUS_BODY='{"status":"in_progress"}' bash "$HERE/coolify-deploy.sh" abc123

# Test 8: trigger returns no deployment_uuid (legacy) -> exit 0 without waiting
make_stub_curl
run_test "legacy trigger without uuid" 0 env COOLIFY_API_URL=https://x.example COOLIFY_API_TOKEN=t STUB_TRIGGER_BODY='{"message":"Deployment request queued."}' bash "$HERE/coolify-deploy.sh" abc123

# Test 9: status endpoint unavailable -> proceeds after 3 attempts, exit 0
make_stub_curl
run_test "status endpoint unavailable" 0 env COOLIFY_API_URL=https://x.example COOLIFY_API_TOKEN=t POLL_INTERVAL=0 STUB_STATUS_HTTP=404 bash "$HERE/coolify-deploy.sh" abc123

rm -f "$HERE/curl"
echo "All tests passed."
