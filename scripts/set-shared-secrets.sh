#!/usr/bin/env bash
# set-shared-secrets.sh - set the 4 shared secrets on every CI'd repo.
#
# Usage: set-shared-secrets.sh [<repo>...]   # defaults to all in apps.yaml
#
# Required env (read from operator's shell - never hardcode values here):
#   GHCR_TOKEN
#   COOLIFY_API_TOKEN
#   TELEGRAM_TOKEN
#   TELEGRAM_CHAT
#
# Validates each is set before doing any work.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_YAML="${HERE}/../apps.yaml"

for required in GHCR_TOKEN COOLIFY_API_TOKEN TELEGRAM_TOKEN TELEGRAM_CHAT; do
  if [ -z "${!required:-}" ]; then
    echo "ERROR: env var $required is not set" >&2
    exit 2
  fi
done

# Default to all repos from apps.yaml if no positional args
if [ $# -gt 0 ]; then
  repos=("$@")
else
  mapfile -t repos < <(yq -r '.apps[].repo, .multi_apps[].repo' "$APPS_YAML" | sort -u)
fi

for repo in "${repos[@]}"; do
  echo "→ $repo"
  for name in GHCR_TOKEN COOLIFY_API_TOKEN TELEGRAM_TOKEN TELEGRAM_CHAT; do
    printf '%s' "${!name}" | gh secret set "$name" -R "$repo"
    echo "    $name set"
  done
done
