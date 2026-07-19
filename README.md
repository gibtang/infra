# gibtang/infra

Reusable GitHub Actions workflows and shell scripts that build, push, and
deploy the Coolify app fleet. Replaces the dead Jenkins host.

> **Visibility:** This repo is intentionally **public**. GitHub requires
> reusable workflows to be accessible to callers; for a user-owned account
> (not an org) that means public. No secrets live here — only CI orchestration
> and references to secret names. All actual values are stored as repo-level
> secrets on each app repo.

## What lives here

- `.github/workflows/build-deploy.yml` — reusable workflow called by each app
- `.github/workflows/build-deploy-multi.yml` — variant for multi-image monorepos (iguana_docs)
- `scripts/` — supporting shell scripts (deploy, notify, secret extraction)
- `apps.yaml` — fleet inventory
- `docs/` — onboarding + secrets docs

## How an app deploys

Each app repo has a `.github/workflows/deploy.yml` like:

```yaml
jobs:
  deploy:
    uses: gibtang/infra/.github/workflows/build-deploy.yml@v1
    with:
      image: ghcr.io/gibtang/<app>
      app_uuid: <coolify-uuid>
      build_args: 'NEXT_PUBLIC_FOO,NEXT_PUBLIC_BAR'
    secrets: inherit
```

On push to `main`, it builds the image, pushes to GHCR with `:latest` +
`:github-<run>` tags, then POSTs to Coolify to redeploy.

See `docs/adding-a-new-app.md` to onboard a new app.
