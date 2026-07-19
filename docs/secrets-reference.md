# Secrets reference

## Shared secrets (set on every CI'd repo)

| Secret | Source | Purpose |
|---|---|---|
| `GHCR_TOKEN` | GitHub PAT with `write:packages` scope | Push images to ghcr.io |
| `COOLIFY_API_TOKEN` | Coolify → API Tokens | Trigger deploy via POST /api/v1/deploy |
| `TELEGRAM_TOKEN` | BotFather bot token | Send pipeline notifications |
| `TELEGRAM_CHAT` | Numeric chat ID | Primary notification target |

The agent group `-1003669787601` is hardcoded in `scripts/telegram-notify.sh` —
notifications always go to both chats.

> **Note:** `gibtang` is a user account, not an org, so there is no
> org-level secret sharing. The 4 shared secrets above are set per-repo via
> `scripts/set-shared-secrets.sh`. The cost is one-time setup + maintenance
> on rotation.

## Per-app secrets (build-args)

Each app may have additional secrets for its `--build-arg` list. These are
populated by `scripts/extract-build-args.sh` and consumed by the reusable
workflow's caller `env:` block (see `docs/adding-a-new-app.md`).

Two recovery sources, in order:
1. **Coolify API** — `/api/v1/applications/{uuid}/envs` returns plaintext
   values. Covers any build-arg that is also used at runtime (typical for
   `MONGODB_URI`, `REDIS_URL`, server-side API keys).
2. **Running container** — `NEXT_PUBLIC_*` values are inlined into the
   Next.js bundle at build time. `extract-build-args.sh` greps the running
   container's `/app/.next/**/*.js` for known patterns.

## Non-secrets (hardcoded)

- `COOLIFY_API_URL` = `https://coolify-api.feedcode.dev` — hardcoded in
  workflow files and `scripts/coolify-deploy.sh`
- Agent group chat ID `-1003669787601` — hardcoded in
  `scripts/telegram-notify.sh`

## Rotating a shared secret

1. Generate new value (e.g., a new GitHub PAT at
   https://github.com/settings/tokens)
2. Set it in your shell: `export GHCR_TOKEN=...`
3. Run `scripts/set-shared-secrets.sh` (loops all 18 repos)
4. Verify by triggering a manual deploy on any app
