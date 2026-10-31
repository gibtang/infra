#!/usr/bin/env bash
# coolify-deploy.sh - trigger Coolify redeploy for one or more application UUIDs
# and wait until each deployment reaches a terminal state.
#
# Usage: coolify-deploy.sh <uuid> [<uuid> ...]
#
# Env:
#   COOLIFY_API_URL    Base URL (default: https://coolify-api.feedcode.dev)
#   COOLIFY_API_TOKEN  API token (required)
#   DEPLOY_TIMEOUT     Max seconds to wait per deployment (default: 900)
#   POLL_INTERVAL      Seconds between status polls (default: 10)
#
# The POST /api/v1/deploy response carries a deployment_uuid; we poll
# GET /api/v1/deployments/<deployment_uuid> until the status is:
#   finished           -> success
#   failed|cancelled|error -> failure
# Unknown statuses keep polling. If the status endpoint is unavailable
# (older Coolify), we log a warning and stop waiting instead of blocking.
#
# Exits 0 if all deployments finished, non-zero otherwise:
#   2 = no UUID provided
#   3 = missing COOLIFY_API_TOKEN
#   4 = one or more deploys failed or were cancelled
#   5 = timed out waiting for a deployment
set -euo pipefail

COOLIFY_API_URL="${COOLIFY_API_URL:-https://coolify-api.feedcode.dev}"
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-900}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"

if [ $# -eq 0 ]; then
  echo "Usage: $0 <uuid> [<uuid> ...]" >&2
  exit 2
fi

if [ -z "${COOLIFY_API_TOKEN:-}" ]; then
  echo "ERROR: COOLIFY_API_TOKEN is not set" >&2
  exit 3
fi

# Print one field of a JSON document to stdout; exit non-zero when absent.
json_field() { # <json> <field>
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
v = data.get(sys.argv[1])
if v is None:
    sys.exit(1)
print(v)
' "$2" 2>/dev/null
}

# HTTP request against the Coolify API. Prints the status code to stdout;
# writes the response body to HTTP_BODY_FILE (command substitution runs in a
# subshell, so a variable assignment would not survive).
HTTP_BODY_FILE="$(mktemp)"
trap 'rm -f "$HTTP_BODY_FILE"' EXIT

http() { # <GET|POST> <url> [json-body]
  local method="$1" url="$2" body="${3-}" code
  if [ "$method" = "POST" ]; then
    code="$(curl -s -o "$HTTP_BODY_FILE" -w '%{http_code}' -X POST "$url" \
      -H "Authorization: Bearer ${COOLIFY_API_TOKEN}" \
      -H 'Content-Type: application/json' \
      -d "$body")"
  else
    code="$(curl -s -o "$HTTP_BODY_FILE" -w '%{http_code}' "$url" \
      -H "Authorization: Bearer ${COOLIFY_API_TOKEN}")"
  fi
  printf '%s' "$code"
}

wait_for_deployment() { # <deployment_uuid> -> 0 finished | 1 failed | 2 timed out
  local dep_uuid="$1" waited=0 status poll_fails=0
  while true; do
    code="$(http GET "${COOLIFY_API_URL}/api/v1/deployments/${dep_uuid}")"
    if [ "$code" = "200" ]; then
      poll_fails=0
      status="$(json_field "$(cat "$HTTP_BODY_FILE")" status || true)"
      status="${status:-unknown}"
      echo "    ${dep_uuid}: status=${status} waited=${waited}s"
      case "$status" in
        finished)
          return 0 ;;
        failed|cancelled|error)
          echo "    ERROR: deployment ${dep_uuid} ended with status '${status}'" >&2
          return 1 ;;
      esac
    else
      poll_fails=$((poll_fails + 1))
      echo "    WARN: status poll for ${dep_uuid} returned HTTP ${code} (attempt ${poll_fails})" >&2
      if [ "$poll_fails" -ge 3 ]; then
        echo "    WARN: status endpoint unavailable; proceeding without waiting (legacy API?)" >&2
        return 0
      fi
    fi
    if [ "$waited" -ge "$DEPLOY_TIMEOUT" ]; then
      echo "    ERROR: timed out after ${DEPLOY_TIMEOUT}s waiting for ${dep_uuid} (last status: ${status:-n/a})" >&2
      return 2
    fi
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
  done
}

fail=0
for uuid in "$@"; do
  code="$(http POST "${COOLIFY_API_URL}/api/v1/deploy" "{\"uuid\":\"${uuid}\"}")"
  body="$(cat "$HTTP_BODY_FILE")"
  echo "  ${uuid} -> HTTP ${code}: ${body}"
  if [ "$code" != "200" ]; then
    echo "  ERROR: deploy failed for ${uuid} (HTTP ${code})" >&2
    fail=4
    continue
  fi
  dep_uuid="$(json_field "$body" deployment_uuid || true)"
  if [ -z "$dep_uuid" ]; then
    echo "  WARN: no deployment_uuid in trigger response; skipping wait (legacy API?)" >&2
    continue
  fi
  echo "  waiting for deployment ${dep_uuid} (timeout ${DEPLOY_TIMEOUT}s)..."
  rc=0
  wait_for_deployment "$dep_uuid" || rc=$?
  if [ "$rc" = "2" ]; then
    fail=5
  elif [ "$rc" != "0" ]; then
    fail=4
  fi
done

exit $fail
