#!/usr/bin/env bash
# coolify-deploy.sh - trigger Coolify redeploy for one or more application UUIDs.
#
# Usage: coolify-deploy.sh <uuid> [<uuid> ...]
#
# Env:
#   COOLIFY_API_URL    Base URL (default: https://coolify-api.feedcode.dev)
#   COOLIFY_API_TOKEN  API token (required)
#
# Optional - exact commit attribution (see deployments-report):
#   After each successful deploy the response carries a `deployment_uuid`
#   (the exact row Coolify creates in application_deployment_queues). If the
#   Redis + DEPLOY_SHA env below are set, we record a small JSON record keyed
#   by that deployment_uuid so deployments-report can attribute the commit
#   exactly instead of guessing by timestamp. Recording is best-effort: any
#   failure only logs a warning and never fails the deploy.
#
#   REDIS_URL              redis://[:password@]host:port[/db]  (redis-cli -u)
#   DEPLOY_SHA             exact commit SHA            (e.g. $GITHUB_SHA)
#   DEPLOY_COMMIT_MESSAGE  first line of the commit message
#   DEPLOY_COMMIT_URL      permalink to the commit on GitHub
#   DEPLOY_REPO            owner/repo   (optional, for display)
#   DEPLOY_RUN_URL         GitHub Actions run URL (optional, for display)
#   DEPLOY_AUTHOR          github.actor (optional, for display)
#   DEPLOY_META_TTL        Redis key TTL seconds (default 16 days)
#
# Exits 0 if all UUIDs returned HTTP 200, non-zero otherwise:
#   2 = no UUID provided
#   3 = missing COOLIFY_API_TOKEN
#   4 = one or more deploys failed
set -euo pipefail

COOLIFY_API_URL="${COOLIFY_API_URL:-https://coolify-api.feedcode.dev}"
DEPLOY_META_TTL="${DEPLOY_META_TTL:-1382400}"   # 16 days (> report's 14-day window)

if [ $# -eq 0 ]; then
  echo "Usage: $0 <uuid> [<uuid> ...]" >&2
  exit 2
fi

if [ -z "${COOLIFY_API_TOKEN:-}" ]; then
  echo "ERROR: COOLIFY_API_TOKEN is not set" >&2
  exit 3
fi

# Recording is opt-in: needs Redis + a SHA + redis-cli on PATH.
want_record() {
  [ -n "${REDIS_URL:-}" ] \
    && [ -n "${DEPLOY_SHA:-}" ] \
    && command -v redis-cli >/dev/null 2>&1
}

# redis-cli's -u rejects an empty userinfo (the server uses ACL user 'default');
# normalize the conventional "redis://:pass@host" to "redis://default:pass@host".
redis_cli_url() {
  case "${REDIS_URL:-}" in
    redis://:*) printf 'redis://default:%s' "${REDIS_URL#redis://:}" ;;
    *) printf '%s' "${REDIS_URL}" ;;
  esac
}

# Build the metadata payload with jq so commit messages with quotes / special
# chars are quoted safely.
build_payload() {
  jq -nc \
    --arg sha         "${DEPLOY_SHA:-}" \
    --arg message     "${DEPLOY_COMMIT_MESSAGE:-}" \
    --arg url         "${DEPLOY_COMMIT_URL:-}" \
    --arg repo        "${DEPLOY_REPO:-}" \
    --arg run_url     "${DEPLOY_RUN_URL:-}" \
    --arg author      "${DEPLOY_AUTHOR:-}" \
    --arg recorded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{sha:$sha, message:$message, url:$url, repo:$repo, run_url:$run_url, author:$author, recorded_at:$recorded_at}'
}

record_meta() {
  local duuid="$1" payload
  if ! payload="$(build_payload 2>/dev/null)"; then
    echo "  warn: could not build commit metadata payload" >&2
    return 0
  fi
  if redis-cli -u "$(redis_cli_url)" --no-auth-warning \
       SET "deployments:meta:${duuid}" "$payload" EX "$DEPLOY_META_TTL" >/dev/null 2>&1; then
    echo "  recorded commit metadata for deployment ${duuid}"
  else
    echo "  warn: failed to write metadata to Redis (deploy still ok)" >&2
  fi
}

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

  if [ "$code" = "200" ]; then
    # Coolify returns: {"deployments":[{"deployment_uuid":"<duuid>", ...}]}
    duuid="$(printf '%s' "$body" | jq -r '.deployments[0].deployment_uuid // empty' 2>/dev/null || true)"
    if [ -n "$duuid" ]; then
      echo "deployment_uuid=${duuid}"   # machine-readable line for callers/logs
      if want_record; then record_meta "$duuid" || true; fi
    else
      echo "  warn: no deployment_uuid in Coolify response - metadata not recorded" >&2
    fi
  else
    echo "  ERROR: deploy failed for ${uuid} (HTTP ${code})" >&2
    fail=1
  fi
done

exit $fail
