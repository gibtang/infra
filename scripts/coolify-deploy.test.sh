#!/usr/bin/env bash
# Smoke test for coolify-deploy.sh using a stubbed curl.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Stub curl: simulate -o <file> (body) + -w '%{http_code}' (stdout).
# Real curl writes the body to the -o file and the -w format string to stdout.
# Our stub parses -o and -w, then mimics that contract. The body emitted is
# taken from $STUB_BODY (default: "stubbed-body"); when set to "json" it emits
# a realistic Coolify deploy response carrying a deployment_uuid.
CURL_LOG="$(mktemp)"
stub_curl() {
  cat > "$HERE/curl" <<'EOF'
#!/usr/bin/env bash
# Log the invocation
out_file=""
fmt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out_file="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "${STUB_BODY:-}" in
  json) echo '{"deployments":[{"message":"Deployment queued.","resource_uuid":"app-uuid","deployment_uuid":"abc-123-def"}]}' > "$out_file" ;;
  *)    echo "stubbed-body" > "$out_file" ;;
esac
# Real curl would substitute %{http_code} in fmt; our stub assumes the
# caller used -w '%{http_code}' and returns 200.
[ -n "$fmt" ] && echo 200
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

# Override PATH so 'curl' resolves to our stub
PATH="$HERE:$PATH"

# Test 1: missing UUID -> exit 2
stub_curl
export COOLIFY_API_TOKEN=fake-token
run_test "no uuid argument" 2 env COOLIFY_API_URL=https://x.example COOLIFY_API_TOKEN=t bash "$HERE/coolify-deploy.sh"

# Test 2: success with non-JSON body -> exit 0, no deployment_uuid line
stub_curl
run_test "200 response (non-JSON body)" 0 env COOLIFY_API_URL=https://x.example COOLIFY_API_TOKEN=t bash "$HERE/coolify-deploy.sh" abc123
if grep -q '^deployment_uuid=' /tmp/out; then
  echo "  FAIL: unexpected deployment_uuid line for non-JSON body"; cat /tmp/out; exit 1
fi

# Test 3: missing token -> exit 3
stub_curl
run_test "missing token" 3 env COOLIFY_API_URL=https://x.example COOLIFY_API_TOKEN= bash "$HERE/coolify-deploy.sh" abc123

# Test 4: JSON response -> deployment_uuid echoed to stdout, no crash even when
# REDIS_URL/DEPLOY_SHA are set but redis-cli is absent (graceful skip).
stub_curl
STUB_BODY=json REDIS_URL='redis://x:6379' DEPLOY_SHA=deadbeef \
  run_test "json response echoes deployment_uuid" 0 \
  env COOLIFY_API_URL=https://x.example COOLIFY_API_TOKEN=t STUB_BODY=json \
      REDIS_URL='redis://x:6379' DEPLOY_SHA=deadbeef \
  bash "$HERE/coolify-deploy.sh" abc123
if ! grep -q '^deployment_uuid=abc-123-def$' /tmp/out; then
  echo "  FAIL: deployment_uuid not captured from JSON response"; cat /tmp/out; exit 1
fi
if grep -qi 'recorded commit metadata' /tmp/out; then
  echo "  FAIL: should not record when redis-cli is absent"; cat /tmp/out; exit 1
fi

rm -f "$HERE/curl" "$CURL_LOG"
echo "All tests passed."
