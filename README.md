# A365 Custom Gateway

Tenant-owned Azure control plane that connects **independently hosted** AI agents
to **Microsoft Agent 365** identity and observability, with optional **Prompt
Shields** and **Microsoft Purview** protection.

External agents keep their own hosting and model calls. The Gateway manages
registration, one-time ingress keys, pre-model evaluation receipts, activity /
interaction intake, and optional protection workflows.

**Product definition:** [docs/spec/product-brief.md](docs/spec/product-brief.md)  
**UI platform:** [docs/console/design.md](docs/console/design.md) — React + Fluent
for **all** UIs (Console and Setup); **C# / .NET** remains the backend.

## What you get

| Capability | Role |
|---|---|
| Guided install | Deploy API, worker, hosted UI, SQL, Service Bus, Key Vault |
| Agent registration | Reusable blueprint → distinct child Agent ID → Gateway key |
| Registry handoff | Signed-in Administrator completes Agent 365 Registry (Development preview) |
| Data plane | Evaluate prompts → call your model → submit activities / interactions |
| Optional protection | Prompt Shields and/or Purview DLP with review → confirm → execute |
| Optional telemetry | Agent 365 observability (default) and/or Azure Monitor mirror |
| Modern UI platform | React + TypeScript + Fluent UI v9 for Console and Setup (migration in progress) |

**Not in scope:** proxying the model, production Registry admission, deleting
linked Microsoft resources on Gateway registration removal, or rewriting the
C# control plane into another backend language.

## Platform direction

| Layer | Direction |
|---|---|
| Backend | Stay on C# / .NET (API, worker, Purview executor, migrator) |
| Installer engine | Stay on PowerShell bootstrap (`gateway` / `gateway.cmd`) |
| All UIs | Move completely to React + Fluent — including guided Setup |

Today, bootstrap still deploys the **Blazor Admin UI** and launches the legacy
**Setup** app. Those are transitional. New UI work follows the
[UI design system](docs/console/design.md).

## Build and install

Requirements: Git, PowerShell 7, Azure CLI, and the .NET SDK from
[global.json](global.json). Windows Purview packaging needs the exact signed
runtimes in the [bootstrap guide](bootstrap/README.md).

```powershell
dotnet build .\src\A365Gateway.slnx --configuration Release
.\gateway.cmd setup
```

On macOS or Linux: `./gateway setup`. Terminal lifecycle:

```text
doctor -> init -> plan -> apply -> verify
                          resume after an eligible interruption
```

Registry provisioning is an explicitly acknowledged **Development-only** preview.
Staging and production admission remain closed. Deployment health does not prove
telemetry delivery or policy enforcement.

## Connect an external agent

1. Sign in to the hosted operator UI (today: bootstrap-deployed **Blazor Admin UI**;
   target: **React Console**) and open **Getting started** / Agents.
2. Register an agent on a new or compatible existing identity blueprint.
3. Review optional telemetry and protection choices when the UI offers them
   (legacy Admin UI may include them at registration; target Console keeps
   registration to name → blueprint → key and places controls on Agents / Data protection).
4. Save the API endpoint, external agent ID, and one-time Gateway key securely.
5. Complete the signed-in administrator handoff for Agent 365 Registry creation.
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

Do not auto-retry uncertain ingestion or invent replacement proof after
generation. Keep secrets and real prompt/response content out of command
arguments and logs.

See the [API guide](docs/api/api-contract.md) and [OpenAPI](docs/api/openapi.yaml).

## Optional protection and telemetry

| Capability | Purpose |
|---|---|
| Agent 365 observability | Registration-scoped sanitized activity export |
| Azure Monitor mirror | Independently selected sanitized monitoring telemetry |
| Prompt Shields | Prompt-attack evaluation before the external model call |
| Microsoft Purview | Tenant connection, shared blueprint DLP, runtime evidence |

Both protections Off is a complete core registration. Requested On defaults are
not silently rewritten when prerequisites are unavailable.

Purview setup follows: **Connect tenant** → **Set shared policy** →
**Test behavior** → **Review agent choices**. Simulation and saved configuration
do not prove current enforcement. Shared DLP uses the blueprint Individual scope;
optional Know Your Data uses its fixed tenant-wide Group. Runtime samples need
explicit review and approval.

## Repository layout

| Directory | Contents |
|---|---|
| [src](src) | Gateway API, worker, Blazor Admin UI (legacy hosted UI), providers, sample client |
| [web/console](web/console) | React + Fluent Console (target hosted UI; bootstrap cutover unfinished) |
| [tools](tools) | Legacy Setup UI, database migrator, installer helpers (Setup UI to be replaced) |
| [bootstrap](bootstrap) | PowerShell installer engine, configuration, foundation templates |
| [infrastructure](infrastructure) | Workload Bicep and ordered SQL assets |
| [operations](operations) | Maintenance and read-only deployment verification |
| [docs](docs/README.md) | Product, architecture, UI, and API documentation |

## Documentation map

| Need | Start here |
|---|---|
| Objective, scope, features, behaviors, UI platform | [Product brief](docs/spec/product-brief.md) |
| UI stack and design system (all UIs) | [UI design](docs/console/design.md) |
| Components and workflows | [System architecture](docs/architecture/system-architecture.md) |
| Installer details | [Bootstrap](bootstrap/README.md) |
| Existing installation | [Operations](operations/README.md) |
| Full index | [docs/README.md](docs/README.md) |
