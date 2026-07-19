#!/usr/bin/env bash
# Unit test for extract-build-args.sh - verifies the value-resolution logic
# using stubbed Coolify API responses and stubbed docker exec output.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the script without running main, so we can unit-test its functions.
# extract-build-args.sh must expose: resolve_value_from_coolify, resolve_value_from_container
# (Functions only - the script's main body is guarded by BASH_SOURCE check.)

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  OK: $name"; pass=$((pass+1))
  else
    echo "  FAIL: $name (expected '$expected' got '$actual')"; fail=$((fail+1))
  fi
}

pass=0; fail=0

# Stub COOLIFY_ENVS_JSON - a function that the script calls to fetch the envs.
# Our stub returns a fake env list.
export COOLIFY_ENVS_JSON='[{"key":"NEXT_PUBLIC_FOO","real_value":"ABC123"},{"key":"MONGODB_URI","real_value":"mongodb://x"}]'

# Script's parameter expansion runs on source, so set the required env first.
export COOLIFY_API_TOKEN=fake-token-for-test

# Source the script (functions only - main is guarded).
source "$HERE/extract-build-args.sh"

# Test resolve_value_from_coolify: returns value if key present
assert_eq "coolify finds key"        "ABC123"        "$(resolve_value_from_coolify NEXT_PUBLIC_FOO)"
assert_eq "coolify missing key"      ""              "$(resolve_value_from_coolify NEXT_PUBLIC_MISSING)"

# Test resolve_value_from_container: greps stubbed docker output.
# Write the bundle to a temp file (the script reads $CONTAINER_STRINGS_FILE).
CONTAINER_STRINGS_FILE="$(mktemp)"
printf '%s' 'var x="AIzaSyDNidVpEUSNkF2eFIS_L_wJuMTWKDd0z-g";' > "$CONTAINER_STRINGS_FILE"
export CONTAINER_STRINGS_FILE

assert_eq "container finds firebase key"  "AIzaSyDNidVpEUSNkF2eFIS_L_wJuMTWKDd0z-g" \
  "$(resolve_value_from_container 'AIza[A-Za-z0-9_-]{35}')"
assert_eq "container no match"            "" \
  "$(resolve_value_from_container 'NOMATCH_[A-Z]+')"

echo
echo "Passed: $pass  Failed: $fail"
[ "$fail" = 0 ] || exit 1
