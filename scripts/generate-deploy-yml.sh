#!/usr/bin/env bash
# generate-deploy-yml.sh - generate a per-app deploy.yml from apps.yaml.
#
# Usage: generate-deploy-yml.sh <app-name> [output-path]
#
# Default output: ./deploy.yml (overwrite ready to commit).
#
# Reads the app's entry from apps.yaml and produces a self-contained
# .github/workflows/deploy.yml that:
#   - Builds the docker image with --build-arg for each name in build_args
#   - Pushes :latest + :github-<run_number> to GHCR
#   - Triggers Coolify deploy
#   - Sends Telegram notifications (start/success/failure/abort)
#
# This is the ONLY correct pattern post-Phase 4 redesign: GitHub Actions
# forbids passing secret-derived values to reusable workflows, so each app
# owns its build step. The shared scripts come from gibtang/infra via checkout.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_YAML="${HERE}/../apps.yaml"

if [ $# -lt 1 ]; then
  echo "Usage: $0 <app-name> [output-path]" >&2
  exit 2
fi
app_name="$1"
out="${2:-./deploy.yml}"

# Read fields from apps.yaml
image="$(yq -r ".apps[] | select(.name == \"$app_name\") | .image" "$APPS_YAML")"
uuid="$(yq -r ".apps[] | select(.name == \"$app_name\") | .coolify_uuid" "$APPS_YAML")"
dockerfile="$(yq -r ".apps[] | select(.name == \"$app_name\") | .dockerfile // \"Dockerfile\"" "$APPS_YAML")"
context="$(yq -r ".apps[] | select(.name == \"$app_name\") | .context // \".\"" "$APPS_YAML")"

if [ -z "$image" ]; then
  echo "ERROR: app '$app_name' not found in apps.yaml (or is a multi_apps entry)" >&2
  exit 3
fi

# Build the env: and --build-arg blocks
env_block=""
args_block=""
while IFS= read -r name; do
  [ -z "$name" ] && continue
  env_block+="          ${name}: \${{ secrets.${name} }}\n"
  args_block+="            --build-arg ${name}=\"\$${name}\" \\\\\n"
done < <(yq -r ".apps[] | select(.name == \"$app_name\") | .build_args[]" "$APPS_YAML" 2>/dev/null)

# If we have build-args, the docker build line needs the args + a trailing line continuation
# If not, the docker build line is plain.
if [ -n "$args_block" ]; then
  # Trim trailing " \\\n" from args_block
  args_block="${args_block% \\\\*}"
  build_cmd="          docker build \\\\\n${args_block} \\\\\n            -f \"${dockerfile}\" \\\\\n            -t \"${image}:latest\" \\\\\n            -t \"${image}:github-\${{ github.run_number }}\" \\\\\n            \"${context}\""
  env_header="        env:\n"
else
  build_cmd="          docker build \\\\\n            -f \"${dockerfile}\" \\\\\n            -t \"${image}:latest\" \\\\\n            -t \"${image}:github-\${{ github.run_number }}\" \\\\\n            \"${context}\""
  env_header=""
fi

# Emit the deploy.yml
cat > "$out" <<EOF
name: deploy
on:
  push:
    branches: [main]
  workflow_dispatch:
concurrency:
  group: deploy-\${{ github.ref }}
  cancel-in-progress: true
permissions:
  contents: read
env:
  COOLIFY_API_URL: https://coolify-api.feedcode.dev
jobs:
  deploy:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - name: Checkout app repo
        uses: actions/checkout@v4

      - name: Checkout infra (scripts)
        uses: actions/checkout@v4
        with:
          repository: gibtang/infra
          path: .infra

      - name: Notify start
        if: always()
        env:
          TELEGRAM_TOKEN: \${{ secrets.TELEGRAM_TOKEN }}
          TELEGRAM_CHAT: \${{ secrets.TELEGRAM_CHAT }}
        run: |
          msg="🔨 <b>${image}</b> #\${{ github.run_number }} — build started"
          bash .infra/scripts/telegram-notify.sh "\$msg" || true

      - name: Login to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: \${{ github.actor }}
          password: \${{ secrets.GHCR_TOKEN }}

      - name: Build
$(if [ -n "$env_block" ]; then printf '%b' "$env_header"; printf '%b' "$env_block"; fi)
        run: |
          set -euo pipefail
$(printf '%b' "$build_cmd")

      - name: Push
        run: |
          docker push "${image}:latest"
          docker push "${image}:github-\${{ github.run_number }}"

      - name: Deploy via Coolify
        env:
          COOLIFY_API_TOKEN: \${{ secrets.COOLIFY_API_TOKEN }}
        run: |
          bash .infra/scripts/coolify-deploy.sh "${uuid}"

      - name: Notify success
        if: success()
        env:
          TELEGRAM_TOKEN: \${{ secrets.TELEGRAM_TOKEN }}
          TELEGRAM_CHAT: \${{ secrets.TELEGRAM_CHAT }}
        run: |
          msg="✅ <b>${image}</b> #\${{ github.run_number }} — deploy SUCCESS: \${{ github.server_url }}/\${{ github.repository }}/actions/runs/\${{ github.run_id }}"
          bash .infra/scripts/telegram-notify.sh "\$msg" || true

      - name: Notify failure
        if: failure()
        env:
          TELEGRAM_TOKEN: \${{ secrets.TELEGRAM_TOKEN }}
          TELEGRAM_CHAT: \${{ secrets.TELEGRAM_CHAT }}
        run: |
          msg="❌ <b>${image}</b> #\${{ github.run_number }} — build FAILED: \${{ github.server_url }}/\${{ github.repository }}/actions/runs/\${{ github.run_id }}"
          bash .infra/scripts/telegram-notify.sh "\$msg" || true

      - name: Notify abort
        if: cancelled()
        env:
          TELEGRAM_TOKEN: \${{ secrets.TELEGRAM_TOKEN }}
          TELEGRAM_CHAT: \${{ secrets.TELEGRAM_CHAT }}
        run: |
          msg="⏹ <b>${image}</b> #\${{ github.run_number }} — build ABORTED"
          bash .infra/scripts/telegram-notify.sh "\$msg" || true
EOF

echo "Wrote $out for $app_name (${image})" >&2
