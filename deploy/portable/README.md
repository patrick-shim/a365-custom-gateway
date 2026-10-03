# Portable local runtime

Zero-Microsoft **infrastructure** on Docker Compose. Product APIs (Entra, Graph,
Agent 365, Purview, Prompt Shields) remain external Microsoft services.

**Full engineer handoff (auth, FMI, Registry, troubleshooting):**
[docs/portable/README.md](../../docs/portable/README.md).

## Full stack (recommended)

Guided bootstrap builds images, creates Entra apps/secrets, writes gitignored
`.env.runtime`, and starts infra + API + worker + **React Console**:

```powershell
.\gateway.cmd up
```

Defaults after apply:

| Surface | URL |
|---|---|
| React Console | `http://127.0.0.1:5081` |
| Gateway API | `http://127.0.0.1:5080` |
| API health | `http://127.0.0.1:5080/health` |

Do **not** hand-edit example JSON as operator input. Wizard writes
`bootstrap/config.json`. Secrets stay in `.bootstrap/secrets/` and
`.env.runtime` (gitignored).

## Compose files

| File | Contents |
|---|---|
| `docker-compose.yml` | PostgreSQL, RabbitMQ (+ management UI), S3 API (`zenko/cloudserver`), Vault dev |
| `docker-compose.apps.yml` | API, provisioning worker, React Console (loads `.env.runtime`) |

### Infrastructure only

```powershell
docker compose -f deploy/portable/docker-compose.yml up -d
```

Ports: postgres `:5432`, rabbitmq `:5672` / UI `:15672`, s3 `:9000`, vault `:8200`.

### Apps after bootstrap has written `.env.runtime`

```powershell
docker compose -f deploy/portable/docker-compose.yml `
  -f deploy/portable/docker-compose.apps.yml `
  --env-file deploy/portable/.env.runtime `
  up -d
```

## Manual API against portable infra

```powershell
$env:ASPNETCORE_ENVIRONMENT = "Portable"
dotnet run --project src/Gateway.Api --launch-profile portable
```

`appsettings.Portable.json` sets `Infrastructure:Provider=Portable` and local
connection defaults. Do **not** also run a local worker against the same RabbitMQ
queue while Compose worker is up — only one consumer should own
`gateway-provisioning-v3`.

## Operator UI

Portable profile ships the **React Console** (`web/console`), not Blazor Admin UI.
Sign in with Entra, register agents, complete **Finish Agent 365 registration**
when prompted, then wait for **Active**.

## Secrets

| File | Commit? |
|---|---|
| `.env.example` | Yes — placeholders only |
| `.env.runtime` | **Never** — bootstrap output |
| `.bootstrap/secrets/*` | **Never** |

Never paste client secrets into git, docs, or chat logs.
