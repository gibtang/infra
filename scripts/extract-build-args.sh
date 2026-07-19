#!/usr/bin/env bash
# extract-build-args.sh - recover build-arg values for one app and write them
# to GitHub as per-repo secrets.
#
# Usage: extract-build-args.sh <app-name>
#
# Reads apps.yaml to find the app's build_args list. For each name:
#   1. Try Coolify API (/api/v1/applications/<uuid>/envs) -> if key present, use real_value
#   2. Else pattern-grep the running container's /app/.next for known NEXT_PUBLIC_* patterns
#   3. Else log a warning - user must set the secret manually
#
# Once a value is resolved, writes it as a repo secret via `gh secret set`.
#
# Env:
#   COOLIFY_API_URL    Base URL (default: https://coolify-api.feedcode.dev)
#   COOLIFY_API_TOKEN  Required
#   DRY_RUN=1          If set: print resolved (key, value) pairs to stderr but
#                      do NOT call gh secret set. Useful for audit before write.
#
# Requires: yq (for parsing apps.yaml), gh (for secret set), curl, docker.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_YAML="${HERE}/../apps.yaml"
COOLIFY_API_URL="${COOLIFY_API_URL:-https://coolify-api.feedcode.dev}"
COOLIFY_API_TOKEN="${COOLIFY_API_TOKEN:?COOLIFY_API_TOKEN is required}"

# Script-level (not local) so the EXIT trap can see it.
_CONTAINER_STRINGS_FILE=""
trap '[ -n "$_CONTAINER_STRINGS_FILE" ] && [ -f "$_CONTAINER_STRINGS_FILE" ] && rm -f "$_CONTAINER_STRINGS_FILE"' EXIT

# ---------- value-resolution functions (unit-tested) ----------

# resolve_value_from_coolify KEY - echo value or empty
# Reads $COOLIFY_ENVS_JSON (set by fetch_coolify_envs) and looks up KEY.
resolve_value_from_coolify() {
  local key="$1"
  python3 -c "
import os, json, sys
try:
    envs = json.loads(os.environ['COOLIFY_ENVS_JSON'])
except Exception:
    sys.exit(0)
for e in envs:
    if e.get('key') == '$key':
        print(e.get('real_value', ''))
        break
"
}

# resolve_value_from_container PATTERN - echo first match or empty
# Greps $CONTAINER_STRINGS_FILE (set by fetch_container_strings) for PATTERN.
resolve_value_from_container() {
  local pattern="$1"
  [ -z "${CONTAINER_STRINGS_FILE:-}" ] && return
  [ -f "$CONTAINER_STRINGS_FILE" ] || return
  grep -aoE "$pattern" "$CONTAINER_STRINGS_FILE" 2>/dev/null | head -1 || true
}

# ---------- data-fetching helpers ----------

fetch_coolify_envs() {
  local uuid="$1"
  COOLIFY_ENVS_JSON="$(curl -s \
    -H "Authorization: Bearer ${COOLIFY_API_TOKEN}" \
    "${COOLIFY_API_URL}/api/v1/applications/${uuid}/envs")"
  export COOLIFY_ENVS_JSON
}

fetch_container_strings() {
  # Find the running container for an image ref, dump its /app/.next to a temp file.
  # We use a file (not an env var) because the bundle can be multi-MB, which would
  # blow execve's ARG_MAX for every subsequent command in this script.
  local image="$1"
  local container
  container="$(docker ps --filter "ancestor=${image}:latest" --format '{{.Names}}' 2>/dev/null | head -1)"
  _CONTAINER_STRINGS_FILE="$(mktemp)"
  CONTAINER_STRINGS_FILE="$_CONTAINER_STRINGS_FILE"
  if [ -z "$container" ]; then
    return  # empty temp file
  fi
  # Extract only JS / JSON / .body files from /app/.next (Next.js build output).
  docker exec "$container" sh -c '
    find /app/.next -type f \( -name "*.js" -o -name "*.body" -o -name "*.json" \) 2>/dev/null \
      | xargs cat 2>/dev/null
  ' 2>/dev/null > "$_CONTAINER_STRINGS_FILE" || true
  export CONTAINER_STRINGS_FILE
}

# Per-key pattern map for container fallback.
# Each entry is a NEXT_PUBLIC_* name -> regex that matches its value in the bundle.
declare -A PATTERN_FOR=(
  [NEXT_PUBLIC_FIREBASE_API_KEY]='AIza[A-Za-z0-9_-]{35}'
  [NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN]='[a-z0-9-]+\.firebaseapp\.com'
  [NEXT_PUBLIC_FIREBASE_PROJECT_ID]='[a-z0-9-]+\.firebaseapp\.com'
  [NEXT_PUBLIC_FIREBASE_STORAGE_BUCKET]='[a-z0-9-]+\.firebasestorage\.app'
  [NEXT_PUBLIC_FIREBASE_MESSAGING_SENDER_ID]='[0-9]{10,15}'
  [NEXT_PUBLIC_FIREBASE_APP_ID]='1:[0-9]+:web:[a-f0-9]+'
  [NEXT_PUBLIC_GA_MEASUREMENT_ID]='G-[A-Z0-9]{8,}'
  [NEXT_PUBLIC_POSTHOG_KEY]='phc_[A-Za-z0-9]{40,}'
  [NEXT_PUBLIC_POSTHOG_HOST]='(app|us|eu)\.posthog\.com'
  [NEXT_PUBLIC_TURNSTILE_SITE_KEY]='0x4[A-Za-z0-9_]{14,}'
  [NEXT_PUBLIC_APP_URL]='https?://[a-z0-9.-]+'
  [NEXT_PUBLIC_SITE_URL]='https?://[a-z0-9.-]+'
  [NEXT_PUBLIC_BASE_URL]='https?://[a-z0-9.-]+'
)

# ---------- main ----------

resolve_one() {
  local name="$1"
  local value=""

  # 1. Coolify
  value="$(resolve_value_from_coolify "$name")"
  if [ -n "$value" ]; then
    printf '%s' "$value"
    return 0
  fi

  # 2. Container (NEXT_PUBLIC_* only)
  if [[ "$name" == NEXT_PUBLIC_* ]]; then
    local pattern="${PATTERN_FOR[$name]:-}"
    if [ -n "$pattern" ]; then
      value="$(resolve_value_from_container "$pattern")"
      if [ -n "$value" ]; then
        printf '%s' "$value"
        return 0
      fi
    fi
  fi

  return 1
}

main() {
  if [ $# -lt 1 ]; then
    echo "Usage: $0 <app-name>" >&2
    exit 2
  fi
  local app_name="$1"

  # Read app from apps.yaml
  local repo image uuid
  repo="$(yq -r ".apps[] | select(.name == \"$app_name\") | .repo" "$APPS_YAML")"
  image="$(yq -r ".apps[] | select(.name == \"$app_name\") | .image" "$APPS_YAML")"
  uuid="$(yq -r ".apps[] | select(.name == \"$app_name\") | .coolify_uuid" "$APPS_YAML")"
  if [ -z "$repo" ]; then
    echo "ERROR: app '$app_name' not found in apps.yaml" >&2
    exit 3
  fi

  local args
  args="$(yq -r ".apps[] | select(.name == \"$app_name\") | .build_args[]" "$APPS_YAML")"
  if [ -z "$args" ]; then
    echo "[$app_name] no build_args - nothing to do."
    return 0
  fi

  echo "[$app_name] Resolving build-args from Coolify + container..."
  fetch_coolify_envs "$uuid"
  fetch_container_strings "$image"

  local missing=0
  while IFS= read -r name; do
    value="$(resolve_one "$name" || true)"
    if [ -n "$value" ]; then
      if [ "${DRY_RUN:-0}" = "1" ]; then
        # Print key + masked value for audit. For short values (<12 chars),
        # mask fully to avoid leaking most of the value.
        if [ "${#value}" -lt 12 ]; then
          masked="(short - hidden)"
        else
          masked="${value:0:8}...${value: -4}"
        fi
        echo "  $name = $masked  (dry-run, not written)" >&2
      else
        printf '%s' "$value" | gh secret set "$name" -R "$repo" 2>&1 | sed "s/^/    gh: /" >&2
        echo "  $name -> set on $repo" >&2
      fi
    else
      echo "  WARNING: $name NOT RESOLVED - set manually on $repo" >&2
      missing=$((missing+1))
    fi
  done <<< "$args"

  if [ "$missing" -gt 0 ]; then
    echo "[$app_name] $missing value(s) need manual entry." >&2
    return 4
  fi
  echo "[$app_name] done."
}

# Allow sourcing for tests; only run main if invoked directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
