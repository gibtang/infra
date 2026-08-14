# Chatwoot on support.feedcode.dev — Design

Date: 2026-08-05 (approx; day of installation)

## Goal

Self-host Chatwoot (customer-support inbox) on the existing Coolify host
(66.70.190.82), served at **https://support.feedcode.dev**.

Out of scope (deferred, config-only later): Amazon SES inbound email channel
(hello@… → SES → SNS → Chatwoot) and SES transactional outbound mail.

## Why this approach

- **Coolify docker-compose app** — matches how all other apps on this host are
  managed; traefik (`coolify-proxy`) handles TLS/Let's Encrypt automatically.
  `*.feedcode.dev` wildcard DNS already exists.
- **Self-contained stack** — Chatwoot gets its own PostgreSQL and Redis. It
  does NOT touch the host-native shared Redis (6379) or `coolify-db`. Chatwoot's
  Sidekiq + ActionCable pub/sub is Redis-heavy; isolation removes any risk of
  it affecting the ~35 other containers.

## Topology

One Coolify app named `chatwoot`, docker-compose, 4 services:

| Service  | Image                             | Mem limit | Exposed            |
|----------|-----------------------------------|-----------|--------------------|
| rails    | `chatwoot/chatwoot:<stable>`      | 1.2g      | traefik → support.feedcode.dev:443 |
| sidekiq  | `chatwoot/chatwoot:<stable>`      | 800m      | none               |
| postgres | `postgres:13-alpine`              | 500m      | none (no published ports) |
| redis    | `redis:7-alpine`                  | 300m      | none (no published ports) |

Image tag: latest stable v4.x release at install time, pinned (not `latest`).

## Key environment variables

- `SECRET_KEY_BASE` — generated 128-char random hex (stored in Coolify env /
  credentials.md)
- `POSTGRES_PASSWORD` — generated random (stored in Coolify env / credentials.md)
- `RAILS_ENV=production`, `NODE_ENV=production`
- `INSTALLATION_ENV=api`
- `FRONTEND_URL=https://support.feedcode.dev`
- `DEFAULT_LOCALE=en`
- `RAILS_LOG_TO_STDOUT=true`
- `REDIS_URL=redis://redis:6379` (in-stack)
- `POSTGRES_HOST=postgres`, `POSTGRES_DB=chatwoot`, `POSTGRES_USER=postgres`
- `ENABLE_ACCOUNT_SIGNUP=false` (set after admin user exists)

Traefik labels on the `rails` service only: router rule
`Host(\`support.feedcode.dev\`)`, web entrypoint, certresolver = Coolify's LE
resolver.

## Install flow

1. Generate secrets (`SECRET_KEY_BASE`, `POSTGRES_PASSWORD`); record in
   `~/credentials.md` under a new "Chatwoot" section.
2. Create Coolify docker-compose app `chatwoot` with the compose file + env.
3. Deploy. Run DB bootstrap (one-shot `rails db:chatwoot_prepare` +
   migrations) — via a compose init/one-off job or `docker exec` in the rails
   container.
4. Create the admin user (`rails runner` one-liner or onboarding console).
5. Set `ENABLE_ACCOUNT_SIGNUP=false`, redeploy.
6. Verify.

## Verification (success criteria)

- `https://support.feedcode.dev` serves the Chatwoot login page with a valid
  LE certificate.
- `/healthz` (or app root) returns 200.
- Admin login works; a test conversation/inbox can be created.
- Sidekiq UI/queues: no dead-set growth after basic use.
- `docker stats`: each container stays within its memory limit.
- Host memory pressure: swap usage not meaningfully worse than baseline
  (~7.2 GiB used / 4 GiB swap at design time).

## Rollback / risk

- Fully self-contained: stopping & deleting the Coolify app removes all
  Chatwoot footprint (data lives in the app's Postgres volume).
- No other app depends on any Chatwoot component.
- Main risk is host RAM (11 GiB total, tight before install). Mitigated by
  mem limits (~2.8g hard ceiling for the stack) and monitoring post-deploy.

## Deferred: email channel (SES)

Later pass, no re-architecture needed:
- Inbound: verify domain(s) in SES, add MX records, receipt rule → SNS topic →
  HTTPS subscription to Chatwoot's SES ingress endpoint
  (`RAILS_RELATIVE_URL_ROOT` / `MESSENGER_DOMAIN` not required; env:
  `MAILER_INBOUND_EMAIL_DOMAIN` + SES ingress per Chatwoot docs).
- Outbound: SES SMTP credentials → ActionMailer SMTP env vars
  (`SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`,
  `SMTP_AUTHENTICATION=login`, `SMTP_ENABLE_STARTTLS_AUTO=true`,
  `MAILER_SENDER_EMAIL=no-reply@…`).
