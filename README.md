# A365 Custom Gateway

Control plane that connects **independently hosted** AI agents to the Microsoft
services that are this product's purpose: **Entra**, **Graph**, **Agent 365**,
**Purview**, and **Prompt Shields**.

External agents keep their own hosting and model calls. The Gateway manages
registration, one-time ingress keys, pre-model evaluation receipts, activity /
interaction intake, and protection workflows.

**Two layers:**

| Layer | Rule |
|---|---|
| **Product services** | Entra, Graph, Agent 365, Purview, Prompt Shields — **essential** |
| **Infrastructure** | **Zero Microsoft dependence** — PostgreSQL, RabbitMQ, Vault/OpenBao, S3/MinIO, OCI images on **AWS / GCP / on-prem** containers must just work |

No Azure SQL, Service Bus, Key Vault, Container Apps, ACR, or Blob as runtime
requirements.

**Product definition:** [docs/spec/product-brief.md](docs/spec/product-brief.md)  
**UI platform:** [docs/console/design.md](docs/console/design.md) — React + Fluent for all UIs; C# backend  
**Runtime platform:** [docs/architecture/system-architecture.md](docs/architecture/system-architecture.md) — PostgreSQL, RabbitMQ, Vault/OpenBao, S3-compatible storage, Compose/Kubernetes

## What you get

| Capability | Role |
|---|---|
| Guided install | Deploy API, worker, hosted UI, PostgreSQL, RabbitMQ, Vault/OpenBao, object storage |
| Agent registration | Reusable blueprint → distinct child Agent ID → Gateway key |
| Registry handoff | Signed-in Administrator completes Agent 365 Registry (Development preview) |
| Data plane | Evaluate prompts → call your model → submit activities / interactions |
| Protection | Purview + Prompt Shields (essential product services; per-agent usage controls) |
| Telemetry | Agent 365 observability (essential); OpenTelemetry ops mirror (non-Microsoft) |
| Modern UI | React + TypeScript + Fluent UI v9 for Console and Setup (migration in progress) |
| Infra | Same images on AWS ECS/EKS, GCP, or on-prem — **no Microsoft infrastructure** |

**Not in scope:** proxying the model, production Registry admission, deleting
linked Microsoft resources on Gateway registration removal, rewriting the C#
backend, or requiring any Microsoft-hosted infrastructure to run.

## Platform direction

| Layer | Direction |
|---|---|
| Backend | Stay on C# / .NET |
| All UIs | React + Fluent (Console + Setup) |
| Product APIs | Entra, Graph, Agent 365, Purview, Prompt Shields — **keep** |
| Database | PostgreSQL (SQLite local/dev) — **not** Azure SQL |
| Messaging | RabbitMQ — **not** Azure Service Bus |
| Secrets | OpenBao / HashiCorp Vault — **not** Azure Key Vault |
| Content | S3-compatible (e.g. MinIO / AWS S3) |
| Compute | Docker Compose / Kubernetes (ECS/EKS/GKE/…) — **not** Container Apps |
| Images | Any OCI registry (ECR, GCR, GHCR, Harbor, …) |

Legacy Azure PaaS templates in-repo are transitional only.

## Build and install

Requirements: Git, PowerShell 7, the .NET SDK from [global.json](global.json),
and Docker (portable profile). Legacy Azure profile additionally needs Azure CLI.

```powershell
dotnet build .\src\A365Gateway.slnx --configuration Release
.\gateway.cmd setup
```

On macOS or Linux: `./gateway setup`. Terminal lifecycle:

```text
doctor -> init -> plan -> apply -> verify
                          resume after an eligible interruption
```

Choose the deploy profile during setup (portable Compose/Kubernetes target;
legacy Azure only while still supported). Registry provisioning is an explicitly
acknowledged **Development-only** preview. Staging and production admission remain
closed. Deployment health does not prove telemetry delivery or policy enforcement.

## Connect an external agent

**Portable (recommended):** after `.\gateway.cmd up`, open the React Console at
`http://127.0.0.1:5081`. Full portable auth / Registry / Active notes:
[docs/portable/README.md](docs/portable/README.md).

1. Sign in to the hosted operator UI — **React Console on portable**; Blazor Admin
   UI only on the legacy Azure profile until cutover.
2. Register an agent on a new or compatible existing identity blueprint
   (Console: name → blueprint → key).
3. Review optional telemetry and protection choices when offered (Prompt Shields
   on the agent; DLP under Data protection).
4. Save the API endpoint, external agent ID, and one-time Gateway key securely.
5. Complete the signed-in administrator handoff for Agent 365 Registry
   (**Finish Agent 365 registration** → Confirm). This is not Purview approval.
6. Wait for the provisioning worker to verify the registration (**Active**).
7. From the external agent: evaluate each prompt → call your model → submit the
   interaction with the same evaluation receipt.

Expected contracts:

- Key shown once; lost key → replace, not re-register.
- Uncertain create → exact-ID readback, never a second create.
- HTTP 202 → accepted/queued, not Active / delivered / enforced.
- Active registration ≠ optional protection or telemetry ready.
- Delete Gateway registration preserves linked Microsoft resources.

## Sample integration

The [sample client](src/ExternalAgent.Sample/Program.cs) requires HTTPS and reads
the Gateway key through a non-echoing prompt:

```powershell
dotnet run --project .\src\ExternalAgent.Sample -- `
  --api-base-url https://YOUR-GATEWAY-API/ `
  --external-agent-id YOUR-EXTERNAL-AGENT-ID `
  --tenant-user-object-id YOUR-USER-OBJECT-ID `
  --message "Hello through the Gateway"
```

It calls `POST /api/v1/prompts:evaluate` before its fixed-response model stub.
Replace the stub with your model callback while preserving that gate. A valid,
matching, unexpired allow receipt is required before generation and is consumed
once during ingestion.

See the [API guide](docs/api/api-contract.md) and [OpenAPI](docs/api/openapi.yaml).

## Optional protection and telemetry

| Capability | Purpose |
|---|---|
| Agent 365 observability | Registration-scoped sanitized activity export |
| OpenTelemetry mirror | Sanitized monitoring telemetry to operator-chosen backends |
| Prompt Shields | Prompt-attack evaluation before the external model call |
| Microsoft Purview | Tenant connection, shared blueprint DLP, runtime evidence |

Both protections Off is a complete core registration. Simulation and saved
configuration do not prove current enforcement.

## Repository layout

| Directory | Contents |
|---|---|
| [src](src) | Gateway API, worker, legacy Blazor Admin UI, providers, sample client |
| [web/console](web/console) | React + Fluent Console (target hosted UI) |
| [tools](tools) | Legacy Setup UI, database migrator, installer helpers |
| [bootstrap](bootstrap) | Installer engine (portable profiles target; Azure profile transitional) |
| [infrastructure](infrastructure) | Portable-target docs + legacy Bicep/SQL assets |
| [operations](operations) | Maintenance and verification |
| [docs](docs/README.md) | Product, architecture, UI, and API documentation |

## Documentation map

| Need | Start here |
|---|---|
| Objective, scope, features, platforms | [Product brief](docs/spec/product-brief.md) |
| Portable runtime architecture | [System architecture](docs/architecture/system-architecture.md) |
| UI stack (all UIs) | [UI design](docs/console/design.md) |
| Installer / profiles | [Bootstrap](bootstrap/README.md) |
| Portable Compose E2E handoff | [Portable profile](docs/portable/README.md) |
| Infrastructure profiles | [Infrastructure](infrastructure/README.md) |
| Full index | [docs/README.md](docs/README.md) |
