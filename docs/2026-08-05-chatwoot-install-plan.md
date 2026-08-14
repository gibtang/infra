# Chatwoot Installation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy self-contained Chatwoot v4.16.2 (rails + sidekiq + postgres + redis) as a Coolify docker-compose service at https://support.feedcode.dev

**Architecture:** One Coolify Service created via API (`POST /api/v1/services` with `docker_compose_raw`), in a new Coolify project `chatwoot`, on server `localhost` (uuid `ldwez3etrzuvhez7v5q6l029`). Only the `rails` service is exposed via traefik using the service `urls` field. DB bootstrap via `docker exec`.

**Tech Stack:** Docker Compose via Coolify 4.1.2, chatwoot/chatwoot:v4.16.2, postgres:13-alpine, redis:7-alpine.

## Global Constraints

- Domain: `https://support.feedcode.dev` (traefik LE cert; wildcard `*.feedcode.dev` DNS already exists)
- Image tags pinned: `chatwoot/chatwoot:v4.16.2`, `postgres:13-alpine`, `redis:7-alpine` (never `latest`)
- Memory limits: rails 1200m, sidekiq 800m, postgres 500m, redis 300m
- Postgres/Redis publish NO host ports; not reachable outside the compose network
- Does NOT use the host-native shared Redis or coolify-db
- Secrets live in `~/credentials.md` (new "Chatwoot" section) — never committed to git
- Coolify API: `http://localhost:8000/api/v1`, token from `~/credentials.md` (Coolify API section)
- Reference spec: `~/infra/docs/2026-08-05-chatwoot-install-design.md`

---

### Task 1: Generate secrets and record them

**Files:**
- Modify: `~/credentials.md` (append Chatwoot section; this file is NOT in git)

**Interfaces:**
- Produces: `$SECRET_KEY_BASE` (128 hex chars), `$POSTGRES_PASSWORD` (24+ chars, alnum only to avoid URI-encoding issues) used by Tasks 2–5.

- [ ] **Step 1: Generate secrets**

```bash
SECRET_KEY_BASE=$(openssl rand -hex 64)
POSTGRES_PASSWORD=$(openssl rand -hex 16)
echo "SECRET_KEY_BASE=$SECRET_KEY_BASE"
echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
```

Expected: two strings printed; SECRET_KEY_BASE is 128 hex chars, POSTGRES_PASSWORD is 32 hex chars.

- [ ] **Step 2: Append to ~/credentials.md**

Append this section (replace placeholders with actual values):

```markdown
## Chatwoot (support.feedcode.dev)
- Coolify service UUID: <filled in Task 3>
- Coolify project: chatwoot
- URL: https://support.feedcode.dev
- SECRET_KEY_BASE: <value>
- POSTGRES_PASSWORD: <value> (user postgres, db chatwoot, host postgres:5432 inside the compose network only)
```

- [ ] **Step 3: Verify file updated**

Run: `tail -10 ~/credentials.md`
Expected: Chatwoot section visible with real values.

### Task 2: Compose file in infra repo

**Files:**
- Create: `~/infra/services/chatwoot/docker-compose.yml`

**Interfaces:**
- Consumes: env vars `SECRET_KEY_BASE`, `POSTGRES_PASSWORD`, `FRONTEND_URL` (set as Coolify service envs in Task 4 — compose placeholders `${...}` are substituted by Coolify at deploy time).

- [ ] **Step 1: Write the compose file**

```yaml
services:
  rails:
    image: chatwoot/chatwoot:v4.16.2
    restart: always
    command: ['bundle', 'exec', 'rails', 's', '-p', '3000', '-b', '0.0.0.0']
    environment:
      - SECRET_KEY_BASE=${SECRET_KEY_BASE}
      - RAILS_ENV=production
      - NODE_ENV=production
      - INSTALLATION_ENV=api
      - RAILS_LOG_TO_STDOUT=true
      - FRONTEND_URL=${FRONTEND_URL}
      - DEFAULT_LOCALE=en
      - ENABLE_ACCOUNT_SIGNUP=false
      - REDIS_URL=redis://redis:6379
      - POSTGRES_HOST=postgres
      - POSTGRES_PORT=5432
      - POSTGRES_DATABASE=chatwoot
      - POSTGRES_USERNAME=postgres
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - rails-storage:/app/storage
    depends_on:
      - postgres
      - redis
    deploy:
      resources:
        limits:
          memory: 1200m

  sidekiq:
    image: chatwoot/chatwoot:v4.16.2
    restart: always
    command: ['bundle', 'exec', 'sidekiq', '-C', 'config/sidekiq.yml']
    environment:
      - SECRET_KEY_BASE=${SECRET_KEY_BASE}
      - RAILS_ENV=production
      - NODE_ENV=production
      - INSTALLATION_ENV=api
      - RAILS_LOG_TO_STDOUT=true
      - FRONTEND_URL=${FRONTEND_URL}
      - DEFAULT_LOCALE=en
      - ENABLE_ACCOUNT_SIGNUP=false
      - REDIS_URL=redis://redis:6379
      - POSTGRES_HOST=postgres
      - POSTGRES_PORT=5432
      - POSTGRES_DATABASE=chatwoot
      - POSTGRES_USERNAME=postgres
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    depends_on:
      - postgres
      - redis
    deploy:
      resources:
        limits:
          memory: 800m

  postgres:
    image: postgres:13-alpine
    restart: always
    environment:
      - POSTGRES_DB=chatwoot
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - postgres-data:/var/lib/postgresql/data
    deploy:
      resources:
        limits:
          memory: 500m

  redis:
    image: redis:7-alpine
    restart: always
    command: ['redis-server', '--appendonly', 'yes', '--maxmemory', '250mb', '--maxmemory-policy', 'noeviction']
    volumes:
      - redis-data:/data
    deploy:
      resources:
        limits:
          memory: 300m

volumes:
  rails-storage:
  postgres-data:
  redis-data:
```

- [ ] **Step 2: Commit**

```bash
cd ~/infra && git add services/chatwoot/docker-compose.yml
git commit -m "feat(chatwoot): compose file for Coolify deploy (support.feedcode.dev)"
```

Expected: commit succeeds.

### Task 3: Create Coolify project + service

**Interfaces:**
- Consumes: compose file from Task 2 (`$(cat ~/infra/services/chatwoot/docker-compose.yml)`)
- Produces: `$SERVICE_UUID` (Coolify service UUID) used by Tasks 4–7; recorded in `~/credentials.md`.

- [ ] **Step 1: Create project `chatwoot`**

```bash
TOKEN=$(grep -A1 '## Coolify API' ~/credentials.md | grep API | sed 's/.*: //;s/`//g')
curl -s -X POST http://localhost:8000/api/v1/projects \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"chatwoot","description":"Chatwoot support inbox - support.feedcode.dev"}'
```

Expected: JSON with `"name":"chatwoot"` and a `uuid` → save as `$PROJECT_UUID`.

- [ ] **Step 2: Create the service (NOT deployed yet)**

```bash
COMPOSE=$(cat ~/infra/services/chatwoot/docker-compose.yml)
curl -s -X POST http://localhost:8000/api/v1/services \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg c "$COMPOSE" '{
    name: "chatwoot",
    project_uuid: "'$PROJECT_UUID'",
    environment_name: "production",
    server_uuid: "ldwez3etrzuvhez7v5q6l029",
    docker_compose_raw: $c,
    instant_deploy: false,
    urls: [{name: "rails", url: "https://support.feedcode.dev"}]
  }')"
```

Expected: JSON with `uuid` → `$SERVICE_UUID`. Record in `~/credentials.md` Chatwoot section.

- [ ] **Step 3: Verify**

```bash
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8000/api/v1/services/$SERVICE_UUID | jq '.name, .compose_parsing_error // "parse-ok"'
```

Expected: `"chatwoot"`, `"parse-ok"` (or null error).

### Task 4: Set service environment variables

**Interfaces:**
- Consumes: `$SERVICE_UUID`, secrets from Task 1.
- Produces: Coolify service envs that the compose `${...}` placeholders resolve against.

- [ ] **Step 1: Create the env vars**

```bash
SECRET_KEY_BASE=<value from Task 1>
POSTGRES_PASSWORD=<value from Task 1>
curl -s -X POST http://localhost:8000/api/v1/services/$SERVICE_UUID/envs \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg sk $SECRET_KEY_BASE --arg pp $POSTGRES_PASSWORD '{
    key: "SECRET_KEY_BASE", value: $sk, is_build_time: false, is_literal: true
  }')" ; \
curl -s -X POST http://localhost:8000/api/v1/services/$SERVICE_UUID/envs \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg pp $POSTGRES_PASSWORD '{
    key: "POSTGRES_PASSWORD", value: $pp, is_build_time: false, is_literal: true
  }')" ; \
curl -s -X POST http://localhost:8000/api/v1/services/$SERVICE_UUID/envs \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"key":"FRONTEND_URL","value":"https://support.feedcode.dev","is_build_time":false,"is_literal":true}'
```

Expected: each returns a JSON env object (non-error).

- [ ] **Step 2: Verify all three exist**

```bash
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:8000/api/v1/services/$SERVICE_UUID/envs | jq '.[].key'
```

Expected: `SECRET_KEY_BASE`, `POSTGRES_PASSWORD`, `FRONTEND_URL` (plus any Coolify defaults).

### Task 5: Deploy and wait for healthy containers

- [ ] **Step 1: Start the service**

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:8000/api/v1/services/$SERVICE_UUID/start
```

Expected: deployment queued message. Image pull takes several minutes (~1.5 GB chatwoot image).

- [ ] **Step 2: Wait for containers**

```bash
watch -n 10 'docker ps --filter name=chatwoot --format "{{.Names}}\t{{.Status}}"'
```

Expected: 4 containers named `chatwoot-*` (`rails`, `sidekiq`, `postgres`, `redis`) eventually `Up`. Postgres may restart once before rails connects — acceptable if it stabilizes.

### Task 6: Bootstrap the database

**Interfaces:**
- Consumes: running rails container from Task 5.

- [ ] **Step 1: Run chatwoot_prepare**

```bash
RAILS=$(docker ps --filter name=chatwoot --format '{{.Names}}' | grep rails | head -1)
docker exec "$RAILS" bundle exec rails db:chatwoot_prepare
```

Expected: schema migrations run; ends without error. (If `pending migration` errors appear on first try, re-run once — postgres must finish its first init first.)

- [ ] **Step 2: Restart rails + sidekiq**

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:8000/api/v1/services/$SERVICE_UUID/restart
```

Expected: 200/queued; containers come back up.

### Task 7: Verify and close out

- [ ] **Step 1: HTTPS + cert check**

```bash
curl -sI https://support.feedcode.dev | head -5
```

Expected: HTTP/2 200 (after traefik picks up the domain; may 404/502 until rails is ready — retry up to 5 min). Body contains Chatwoot app HTML / onboarding redirect.

- [ ] **Step 2: Login page / onboarding reachable**

```bash
curl -sL https://support.feedcode.dev | grep -io 'chatwoot\|onboarding' | head -3
```

Expected: at least one match.

- [ ] **Step 3: Memory within limits**

```bash
docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}' | grep chatwoot
```

Expected: all containers under their limits (rails <1.2g, sidekiq <800m, postgres <500m, redis <300m). Also `free -h` — swap not meaningfully worse than the ~4.0/4.0 GiB baseline.

- [ ] **Step 4: User creates admin account**

Tell the user: open https://support.feedcode.dev → Chatwoot onboarding wizard → create super-admin account (ENABLE_ACCOUNT_SIGNUP=false does not block this). Confirm they can log in and create an inbox.

- [ ] **Step 5: Update records and commit**

- Fill `Coolify service UUID` in `~/credentials.md` (if not already) 
- Append to `~/infra/apps.yaml` (informational only — no GHCR image, note it):

```yaml
- name: chatwoot
  repo: chatwoot/chatwoot  # upstream image, not our repo
  image: chatwoot/chatwoot:v4.16.2
  coolify_uuid: <SERVICE_UUID>
  build_args: []
  note: docker-compose service (rails+sidekiq+postgres+redis), support.feedcode.dev, manual upgrades via API/UI
```

```bash
cd ~/infra && git add apps.yaml && git commit -m "docs(apps): register chatwoot compose service"
```

Expected: commit succeeds.

---

## Rollback

Stop & delete the Coolify service (`DELETE /api/v1/services/$SERVICE_UUID`) — removes all containers, network, and volumes. No other app is affected.
