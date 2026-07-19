# Adding a new app to CI

Prerequisite: the app already exists in Coolify with `build_pack=dockerimage`,
and its source repo is under `gibtang/`.

## Why each app has its own deploy.yml (not a reusable workflow)

GitHub Actions forbids passing secret-derived values to a reusable workflow
via `with:` inputs (the `secrets` context is not available in `with:`), and
forbids `env:` on jobs that use `uses:`. So the docker build must happen
inline in each app's `deploy.yml`. The shared logic (Coolify deploy, Telegram
notify) lives in `gibtang/infra/scripts/` and is pulled into each run via
`actions/checkout`.

## Steps

### 1. Add an entry to `apps.yaml`

```yaml
apps:
  - name: my-app
    repo: gibtang/my-app
    image: ghcr.io/gibtang/my-app
    coolify_uuid: <find in Coolify UI or via API>
    build_args:
      - NEXT_PUBLIC_FOO   # discover from Dockerfile ARG declarations
```

For a monorepo with multiple images, add to `multi_apps:` instead.

### 2. Set shared secrets on the repo (if not already set)

```bash
bash scripts/set-shared-secrets.sh gibtang/my-app
```

This sets `GHCR_TOKEN`, `COOLIFY_API_TOKEN`, `TELEGRAM_TOKEN`, `TELEGRAM_CHAT`.

### 3. Recover build-arg values

If your app has `build_args:`, recover them from Coolify + the running container:

```bash
COOLIFY_API_TOKEN=$TOKEN bash scripts/extract-build-args.sh my-app
```

Add `DRY_RUN=1` to preview without writing.

### 4. Create `.github/workflows/deploy.yml` in the app repo

Copy `docs/deploy-template.yml` from this repo and substitute the
`{{PLACEHOLDERS}}`. Two examples below.

#### Minimal (no build-args)

```yaml
name: deploy
on:
  push:
    branches: [main]
  workflow_dispatch:
concurrency:
  group: deploy-${{ github.ref }}
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
      - uses: actions/checkout@v4
      - uses: actions/checkout@v4
        with:
          repository: gibtang/infra
          path: .infra
      - name: Notify start
        if: always()
        env:
          TELEGRAM_TOKEN: ${{ secrets.TELEGRAM_TOKEN }}
          TELEGRAM_CHAT: ${{ secrets.TELEGRAM_CHAT }}
        run: |
          msg="🔨 <b>ghcr.io/gibtang/my-app</b> #${{ github.run_number }} — build started"
          bash .infra/scripts/telegram-notify.sh "$msg" || true
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GHCR_TOKEN }}
      - name: Build
        run: |
          set -euo pipefail
          docker build -t ghcr.io/gibtang/my-app:latest \
            -t ghcr.io/gibtang/my-app:github-${{ github.run_number }} .
      - name: Push
        run: |
          docker push ghcr.io/gibtang/my-app:latest
          docker push ghcr.io/gibtang/my-app:github-${{ github.run_number }}
      - name: Deploy
        env:
          COOLIFY_API_TOKEN: ${{ secrets.COOLIFY_API_TOKEN }}
        run: bash .infra/scripts/coolify-deploy.sh "<uuid>"
      - name: Notify success
        if: success()
        env:
          TELEGRAM_TOKEN: ${{ secrets.TELEGRAM_TOKEN }}
          TELEGRAM_CHAT: ${{ secrets.TELEGRAM_CHAT }}
        run: |
          msg="✅ <b>ghcr.io/gibtang/my-app</b> #${{ github.run_number }} — SUCCESS"
          bash .infra/scripts/telegram-notify.sh "$msg" || true
      - name: Notify failure
        if: failure()
        env:
          TELEGRAM_TOKEN: ${{ secrets.TELEGRAM_TOKEN }}
          TELEGRAM_CHAT: ${{ secrets.TELEGRAM_CHAT }}
        run: |
          msg="❌ <b>ghcr.io/gibtang/my-app</b> #${{ github.run_number }} — FAILED"
          bash .infra/scripts/telegram-notify.sh "$msg" || true
      - name: Notify abort
        if: cancelled()
        env:
          TELEGRAM_TOKEN: ${{ secrets.TELEGRAM_TOKEN }}
          TELEGRAM_CHAT: ${{ secrets.TELEGRAM_CHAT }}
        run: |
          msg="⏹ <b>ghcr.io/gibtang/my-app</b> #${{ github.run_number }} — ABORTED"
          bash .infra/scripts/telegram-notify.sh "$msg" || true
```

#### With build-args

Add an `env:` block to the Build step binding each name to its secret, and
pass `--build-arg NAME="$NAME"` to `docker build`:

```yaml
      - name: Build
        env:
          NEXT_PUBLIC_FOO: ${{ secrets.NEXT_PUBLIC_FOO }}
          MONGODB_URI: ${{ secrets.MONGODB_URI }}
        run: |
          set -euo pipefail
          docker build \
            --build-arg NEXT_PUBLIC_FOO="$NEXT_PUBLIC_FOO" \
            --build-arg MONGODB_URI="$MONGODB_URI" \
            -t ghcr.io/gibtang/my-app:latest \
            -t ghcr.io/gibtang/my-app:github-${{ github.run_number }} .
```

### 5. Trigger a test deploy

In the app repo → Actions tab → "deploy" workflow → Run workflow.

Confirm: image pushed to GHCR, Coolify queues a deploy, Telegram pings arrive
(both primary chat and the agent group `-1003669787601`).
