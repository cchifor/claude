---
name: forge
description: Generate full-stack projects using the forge CLI. Use when the user asks to create, scaffold, generate, or forge a new service, API, application, or microservice platform. Supports Python/FastAPI, Node.js/Fastify, Rust/Axum backends (multiple per project) and Vue 3, Svelte 5, Flutter frontends. Each backend owns its own CRUD entities.
argument-hint: <project-name> [options...]
user-invocable: true
allowed-tools: Bash(forge *) Bash(cat *) Bash(ls *) Bash(docker *) Bash(cd *) Bash(curl *) Bash(sleep *) Read Write
---

# Forge — Full-Stack Project Generator

Generate production-ready projects using the `forge` CLI in headless mode. Supports single-backend and multi-backend (microservices) projects. Traefik API gateway routes all traffic. Each backend has its own migration container.

## Step 1: Parse the user's request

Extract from the arguments or conversation:
- **Project name** (required) — kebab-case, e.g. `my-shop`
- **Backend(s)** — one or more, each with: name, language (`python`|`node`|`rust`), port, and **features** (CRUD entities this backend owns)
- **Frontend** — `vue`, `svelte`, `flutter`, or `none`
- **Auth** — whether to include Keycloak (`--include-auth`)
- **Validate** — whether to run `docker compose up --build` after generation

**IMPORTANT**: Features (CRUD entities) belong to backends, NOT to the frontend. Each backend declares which entities it owns. The frontend auto-generates pages for all backends' features.

## Step 2: Choose the right approach

### A) Single backend — use CLI flags directly

```bash
forge --project-name <name> \
  --backend-language <python|node|rust> \
  --backend-name <service-name> \
  --features "<entities>" \
  --frontend <vue|svelte|flutter|none> \
  --layout <sidebar|topnav|tabbar|threepane|bento|docs> \
  --yes --no-docker --json \
  --output-dir .
```

### B) Multiple backends — write a YAML config file

When the user asks for TWO OR MORE backends, you MUST use a config file.

```bash
cat > /tmp/forge-config.yaml << 'EOF'
project_name: <name>

backends:
  - name: <service-1>
    language: <python|node|rust>
    server_port: 5000
    features: <entity1>, <entity2>
  - name: <service-2>
    language: <python|node|rust>
    server_port: 5001
    features: <entity3>

frontend:
  framework: <vue|svelte|flutter|none>
  layout: <sidebar|topnav|tabbar|threepane|bento|docs>   # default: sidebar
  include_auth: false
EOF

forge --config /tmp/forge-config.yaml --yes --no-docker --json --output-dir .
```

**Port assignment**: Start at 5000, increment by 1 per backend.

## Step 3: Run forge

Always use: `--yes --no-docker --json --output-dir .`

If forge is not installed or outdated:
```bash
uv tool install --force git+https://github.com/cchifor/forge.git
```
From local clone with unpushed changes:
```bash
cd /c/Users/chifo/work/forge && uv tool install --force .
```

## Step 4: Report results

Parse the JSON output. Tell the user:
- Where the project was generated
- What backends were created (name, language, port, features)
- How to start: `cd <project> && docker compose up --build`
- Access at `http://localhost` (Traefik gateway on port 80)
- Dashboard at `http://localhost:8080`

## Step 5: Validate (if the user asks)

Traefik routes all traffic on port 80. Health checks use the pattern `/api/{backend-name}/v1/health/live`:

```bash
cd <project_root>
docker compose up --build -d
sleep 20

# Check each backend through Traefik gateway
curl -sf http://localhost/api/<backend1>/v1/health/live
curl -sf http://localhost/api/<backend2>/v1/health/live

# Check frontend
curl -sf http://localhost/ | head -3

# Test CRUD (create item)
curl -sf -X POST http://localhost/api/<backend1>/v1/<feature> \
  -H "Content-Type: application/json" \
  -d '{"name":"Test","customer_id":"00000000-0000-0000-0000-000000000001","user_id":"00000000-0000-0000-0000-000000000001"}'
```

Stop with: `docker compose down --volumes`

## Worked example

**Prompt**: "Forge a project named test with vue frontend and two backends: tag (python) and notification (node)."

1. Write config:
```bash
cat > /tmp/forge-config.yaml << 'EOF'
project_name: test

backends:
  - name: tag
    language: python
    server_port: 5000
    features: tags
  - name: notification
    language: node
    server_port: 5001
    features: notifications

frontend:
  framework: vue
  include_auth: false
EOF
```

2. Run forge:
```bash
forge --config /tmp/forge-config.yaml --yes --no-docker --json --output-dir .
```

3. Result: `test/` with `tag/` (Python), `notification/` (Node.js), `frontend/` (Vue), `docker-compose.yml` (Traefik + migrate containers).

4. Validate:
```bash
cd test && docker compose up --build -d
sleep 20
curl -sf http://localhost/api/tag/v1/health/live
curl -sf http://localhost/api/notification/v1/health/live
curl -sf http://localhost/api/tag/v1/tags
curl -sf http://localhost/api/notification/v1/notifications
```

## Architecture

```
Traefik :80 (always present)
  /api/tag/*          → tag:5000          (rewrite → /api/v1/tags)
  /api/notification/* → notification:5001 (rewrite → /api/v1/notifications)
  /                   → frontend:80       (nginx static + SPA)

Migration containers (run before backends):
  tag-migrate          → alembic upgrade (Python)
  notification-migrate → prisma migrate deploy (Node.js)

PostgreSQL :5432 — per-backend databases created by init-db.sh
```

## Quick reference

| Flag | Values | Default |
|------|--------|---------|
| `--project-name` | kebab-case | required |
| `--backend-language` | `python`, `node`, `rust` | `python` |
| `--backend-name` | service name | `backend` |
| `--backend-port` | 1024-65535 | `5000` |
| `--features` | comma-separated entities | `items` |
| `--frontend` | `vue`, `svelte`, `flutter`, `none` | `none` |
| `--layout` | `sidebar`, `topnav`, `tabbar`, `threepane`, `bento`, `docs` | `sidebar` |
| `--include-auth` | flag | off |
| `--config FILE` | YAML/JSON path or `-` for stdin | |
| `--output-dir` | path | `.` |
| `--yes` | skip prompts | |
| `--no-docker` | skip docker boot | |
| `--json` | JSON on stdout | |
| `--quiet` | zero output | |

## Config file format

```yaml
project_name: my-platform

backends:
  - name: users
    language: python
    server_port: 5000
    features: users, profiles
  - name: catalog
    language: rust
    server_port: 5001
    features: products, categories
  - name: notifications
    language: node
    server_port: 5002
    features: alerts

frontend:
  framework: vue
  include_auth: true
  package_manager: pnpm

keycloak:
  port: 8080
  realm: my-platform
  client_id: my-platform
```
