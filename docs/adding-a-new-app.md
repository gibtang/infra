# Adding a new app to CI

Prerequisite: the app already exists in Coolify with `build_pack=dockerimage`,
and its source repo is under `gibtang/`.

## Steps

### 1. Add an entry to `apps.yaml`

```yaml
apps:
  - name: my-app
    repo: gibtang/my-app
    image: ghcr.io/gibtang/my-app
    coolify_uuid: <find in Coolify UI or via API>
    build_args:
      - NEXT_PUBLIC_FOO   # if any
```

For a monorepo with multiple images, add to `multi_apps:` instead (see
`iguana_docs` for the format).

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

Single-image (no build-args):

```yaml
name: deploy
on:
  push:
    branches: [main]
  workflow_dispatch:
concurrency:
  group: deploy-${{ github.ref }}
  cancel-in-progress: true
jobs:
  deploy:
    uses: gibtang/infra/.github/workflows/build-deploy.yml@v1
    with:
      image: ghcr.io/gibtang/my-app
      app_uuid: <uuid>
    secrets: inherit
```

Single-image (with build-args):

```yaml
name: deploy
on:
  push:
    branches: [main]
  workflow_dispatch:
concurrency:
  group: deploy-${{ github.ref }}
  cancel-in-progress: true
jobs:
  deploy:
    uses: gibtang/infra/.github/workflows/build-deploy.yml@v1
    with:
      image: ghcr.io/gibtang/my-app
      app_uuid: <uuid>
      build_args: 'NEXT_PUBLIC_FOO,NEXT_PUBLIC_BAR'
    secrets: inherit
    env:
      NEXT_PUBLIC_FOO: ${{ secrets.NEXT_PUBLIC_FOO }}
      NEXT_PUBLIC_BAR: ${{ secrets.NEXT_PUBLIC_BAR }}
```

The `env:` block must list each name in `build_args:`. GitHub Actions forbids
indirect secret access (`${{ secrets[NAME] }}`), so each must be bound
explicitly.

### 5. Trigger a test deploy

In the app repo → Actions tab → "deploy" workflow → Run workflow.

Confirm: image pushed to GHCR, Coolify queues a deploy, Telegram pings arrive
(both primary chat and the agent group `-1003669787601`).
