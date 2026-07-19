#!/usr/bin/env bash
# coolify-deploy.sh - trigger Coolify redeploy for one or more application UUIDs.
#
# Usage: coolify-deploy.sh <uuid> [<uuid> ...]
#
# Env:
#   COOLIFY_API_URL    Base URL (default: https://coolify-api.feedcode.dev)
#   COOLIFY_API_TOKEN  API token (required)
#
# Exits 0 if all UUIDs returned HTTP 200, non-zero otherwise:
#   2 = no UUID provided
#   3 = missing COOLIFY_API_TOKEN
#   4 = one or more deploys failed
set -euo pipefail

COOLIFY_API_URL="${COOLIFY_API_URL:-https://coolify-api.feedcode.dev}"

if [ $# -eq 0 ]; then
  echo "Usage: $0 <uuid> [<uuid> ...]" >&2
  exit 2
fi

if [ -z "${COOLIFY_API_TOKEN:-}" ]; then
  echo "ERROR: COOLIFY_API_TOKEN is not set" >&2
  exit 3
fi

fail=0
for uuid in "$@"; do
  resp_file="$(mktemp)"
  code="$(curl -s -o "$resp_file" -w '%{http_code}' -X POST \
    "${COOLIFY_API_URL}/api/v1/deploy" \
    -H "Authorization: Bearer ${COOLIFY_API_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "{\"uuid\":\"${uuid}\"}")"
  body="$(cat "$resp_file")"
  rm -f "$resp_file"
  echo "  ${uuid} -> HTTP ${code}: ${body}"
  if [ "$code" != "200" ]; then
    echo "  ERROR: deploy failed for ${uuid} (HTTP ${code})" >&2
    fail=1
  fi
done

exit $fail
