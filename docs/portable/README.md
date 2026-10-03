# Portable profile — Codex / engineer handoff

This is the **canonical local runtime** for A365 Custom Gateway. Use it when
continuing work in another agent (Codex, Cursor, etc.). It describes what is
implemented **now**, not aspirational Azure PaaS.

Related docs: [bootstrap](../../bootstrap/README.md) ·
[deploy/portable](../../deploy/portable/README.md) ·
[system architecture](../architecture/system-architecture.md) ·
[Console design](../console/design.md) · [product brief](../spec/product-brief.md).

---

## 1. Non-negotiable product split

| Layer | Rule |
|---|---|
| **Infrastructure** | Zero Microsoft dependence: PostgreSQL, RabbitMQ, Vault (dev), S3-compatible (`zenko/cloudserver`), Docker Compose |
| **Product APIs** | Still Microsoft and essential: Entra, Graph, Agent 365 Registry, Prompt Shields, Purview (optional) |
| **Operator UI** | **React + Fluent Console** (`web/console`) — portable bootstrap deploys it. Do not expand Blazor Admin UI for portable. |

Legacy Azure Bicep / Blazor Admin UI remain in-repo as a **transitional** profile
only. New portable work must not reintroduce Azure SQL, Service Bus, Key Vault,
Container Apps, ACR, or Blob as requirements.

---

## 2. What “up” means (verified E2E)

A portable install is complete when:

1. `gateway.cmd up` (or apply) builds images and starts Compose: postgres, rabbitmq,
   s3, vault, **api**, **worker**, **console**.
2. Operator opens **React Console** (default `http://127.0.0.1:5081`), signs in with Entra.
3. Agent registration reaches **Active** after:
   - blueprint / principal / federation / child Agent ID / observability role
   - **signed-in admin** finishes Agent 365 Registry (delegated; not Purview)
   - worker verifies Graph surface + **observability FMI token proof**

Verified in Contoso-style tenants: agents such as `agent-gw-01` / `agent-gw-02`
reach green **Active** with Registry confirmation and portable FMI secret path.

---

## 3. Operator commands (do not hand-edit secrets into JSON)

```powershell
.\gateway.cmd up          # guided TUI if config missing, then plan/apply
.\gateway.cmd init        # wizard only
.\gateway.cmd doctor
.\gateway.cmd plan
.\gateway.cmd apply
.\gateway.cmd verify
```

- Do **not** pass `config.example*.json` via `--config` (launcher refuses).
- `bootstrap/config.json` is written by the wizard (non-secret IDs only).
- Secrets live under gitignored `.bootstrap/secrets/` and
  `deploy/portable/.env.runtime` (never commit).

Schema samples for developers:

- `bootstrap/config.example.json` — legacy Azure-oriented sample
- `bootstrap/config.example.portable.json` — portable sample

---

## 4. Compose layout

| File | Role |
|---|---|
| `deploy/portable/docker-compose.yml` | Infra: postgres `:5432`, rabbitmq `:5672`/UI `:15672`, s3 `:9000`, vault `:8200` |
| `deploy/portable/docker-compose.apps.yml` | Workloads: api `:5080`, worker, console `:5081` |
| `deploy/portable/.env.runtime` | **Generated** by bootstrap; gitignored; all runtime secrets + Entra IDs |
| `deploy/portable/.env.example` | Non-secret template for manual infra-only experiments |

Images (local tags): `a365-gateway-api:<env>`, `a365-gateway-worker:<env>`,
`a365-gateway-console:<env>` (dev tag commonly `*:dev`).

API / worker use `ASPNETCORE_ENVIRONMENT=Portable` /
`DOTNET_ENVIRONMENT=Portable` and `Infrastructure:Provider=Portable`.

---

## 5. Entra identities bootstrap creates (portable)

| Identity | Purpose |
|---|---|
| Gateway API app | Audience for Console tokens; **OBO** confidential client for Registry Graph scopes |
| Console SPA | Public client; PKCE; redirect to Console origin |
| Workload app | Worker Graph application permissions; Prompt Shields client-secret auth; FIC subject on blueprint |
| Seed Agent Identity blueprint | Shared blueprint; managers from `agent365.reviewedManagerApplicationIds` |

### Secrets (portable only — gitignored)

| Secret | Env / file | Used for |
|---|---|---|
| API OBO client secret | `EntraId__ClientCredentials__0__ClientSecret` | Delegated Registry OBO (ClientSecret source, not managed identity) |
| Workload client secret | `Agent365__ProvisioningClientSecret` | Worker Graph via `ClientSecretCredential` |
| Blueprint FMI secret | `Agent365__BlueprintClientSecret` | Local FMI token exchange for observability verify (Microsoft’s **development** path) |

Azure profile continues to use managed identity + federated credentials; leave
`BlueprintClientSecret` empty there.

### Admin consent (Registry)

Delegated scopes on the API app (must be admin-consented for the tenant):

- `https://graph.microsoft.com/AgentRegistration.ReadWrite.All`
- `https://graph.microsoft.com/AgentRegistration.Read.All`

Without consent, Finish registration fails with a sign-in / consent message in Console.

### Gates that must be on for Console Registry finish

Written into `.env.runtime` by portable bootstrap:

```text
Agent365__DelegatedRegistry__Enabled=true
Agent365__DelegatedRegistry__AllowContinuousDevelopmentAccess=true
ProvisioningWorker__ProvisioningExecutionEnabled=true
```

If the Console shows “Registry completion gate is closed”, those settings are
off in the **API** process. Console cannot flip them; fix env and recreate api.

---

## 6. Observability / Active verification (critical)

Final step `VerifyAgent365Connection` proves FMI:

**Azure / MI path**

1. Managed identity assertion for `api://AzureADTokenExchange`
2. Blueprint token with `client_assertion` + `fmi_path=<agent app id>`
3. Agent identity token for observability audience + `Agent365.Observability.OtelWrite`

**Portable / local path** (implemented)

1. Blueprint authenticates with **`client_secret`** + `fmi_path` (no MI)
2. Same agent-identity exchange as above

Code: `DefaultAzureObservabilityTokenProvider` reads
`Agent365:BlueprintClientSecret`. Bootstrap:
`Ensure-PortableBlueprintClientSecret` in `bootstrap/modules/Portable.psm1`.

Seed blueprint assertions normally forbid secrets; portable allows exactly one
password named `a365gw-bootstrap-portable-blueprint` when the workload SP
authority surface is active.

---

## 7. Registry confirmation UX (Console)

Stage **Add to Microsoft 365 Registry** pauses with
`AwaitingAdministratorAction`. Operator clicks **Finish Agent 365 registration**
→ **Confirm**. That is Gateway admin confirmation into Agent 365 Registry — **not**
Purview approval and not an external inbox.

UI file: `web/console/src/pages/agents/AgentRegistrationProgress.tsx`

- Keep Finish visible when operation error is the awaiting-admin signal
- Retry only after a safely retryable provisioning failure

---

## 8. Worker / queue hygiene

- Only **one** consumer should process `gateway-provisioning-v3`
- Portable worker must have `ProvisioningWorker__ProvisioningExecutionEnabled=true`
- Local `dotnet run` Debug workers against the same RabbitMQ will steal messages —
  stop them before Compose E2E
- Worker Dockerfile installs `libgssapi-krb5-2` for Kerberos/GSS bits needed by
  some Graph/Azure Identity paths in Linux containers

---

## 9. Prompt Shields (portable)

When enabled in wizard:

- Bootstrap can deploy a small Azure AI Content Safety account
  (`infrastructure/bicep/portable-content-safety.bicep`) — product API only
- Runtime auth mode **ClientSecret** for the workload app
  (`PromptShield__AuthMode=ClientSecret`)

---

## 10. Source map (where to change what)

| Concern | Primary paths |
|---|---|
| Portable bootstrap orchestration | `bootstrap/modules/Portable.psm1`, `bootstrap/bootstrap.ps1` |
| Entra apps / OBO secret / consent helpers | `bootstrap/modules/Entra.psm1`, Portable OBO helpers |
| Seed blueprint surface rules | `bootstrap/modules/Agent365.psm1` |
| Runtime env writer | `Write-GatewayPortableRuntimeEnv` in `Portable.psm1` |
| Infra provider switch | `src/Gateway.Infrastructure/InfrastructureProvider.cs` |
| Postgres / RabbitMQ / S3 DI | `src/Gateway.Infrastructure/DependencyInjection.cs` |
| Worker portable host | `src/Gateway.Provisioning.Worker/Program.cs`, `appsettings.Portable.json`, RabbitMq* services |
| API portable host | `src/Gateway.Api/appsettings.Portable.json` |
| FMI / Graph provisioning | `src/Gateway.Agent365/*` |
| Console Registry UX | `web/console/src/pages/agents/AgentRegistrationProgress.tsx` |
| Console proxy | `web/console/nginx.conf` |

---

## 11. Rebuild after code changes

```powershell
# Worker (most Agent365 / FMI / Graph fixes)
docker build -f src/Gateway.Provisioning.Worker/Dockerfile -t a365-gateway-worker:dev .
docker compose -f deploy/portable/docker-compose.yml `
  -f deploy/portable/docker-compose.apps.yml `
  --env-file deploy/portable/.env.runtime `
  up -d --force-recreate --no-deps worker

# API / Console similarly with their Dockerfiles and service names api / console
```

Or re-run `.\gateway.cmd apply` / `up` so `Build-GatewayPortableImages` runs.

---

## 12. Troubleshooting (symptoms → fix)

| Symptom | Likely cause | Fix |
|---|---|---|
| Registry gate closed in Console | DelegatedRegistry flags false | Set env true; recreate **api** |
| Finish hidden / looks Failed | UI treated awaiting-admin as terminal | Console progress component (already fixed) |
| OBO / managed_identity_unreachable | API using MI for OBO on Compose | ClientSecret OBO secret + env |
| Consent / sign-in again on Finish | Missing admin consent for AgentRegistration scopes | Grant oauth2PermissionGrant for API SP |
| Verify fails `ManagedIdentityCredentialUnavailable` | Observability still on MI | Deploy worker with `BlueprintClientSecret` |
| Verify fails `BlueprintTokenHttp401` with workload assertion | Wrong FMI path (using workload secret as MI assertion) | Use **blueprint** client secret path |
| Stuck Not started / no progress | Another worker stole queue or execution disabled | Kill local workers; enable ProvisioningExecutionEnabled |
| CreateAgentIdentity 403/400 | Wrong Graph permission shape | Workload needs Agent Identity **Create.All** (not CreateAsManager alone) for this product path |

---

## 13. What not to do

- Do not make Blazor Admin UI the portable operator surface.
- Do not invent app-only Registry creation — delegated admin stays required.
- Do not commit `.env.runtime`, `.bootstrap/secrets/*`, or real client secrets.
- Do not treat health 200 as Active / Registry / protection proof.
- Do not re-POST Registry create on unknown outcomes — exact-ID readback only.

---

## 14. Quick smoke checklist for the next agent

1. `docker compose … ps` — api, worker, console healthy  
2. Open `http://127.0.0.1:5081` — Entra sign-in works  
3. Register agent → wait through stages → **Finish** → **Confirm**  
4. Status **Active**  
5. If verify fails, check worker logs for `TokenProofCode` / `BlueprintToken*` only
   (never paste secrets into chat)

End of handoff.
