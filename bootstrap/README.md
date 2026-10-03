# Gateway bootstrap

Canonical installation for the product defined in the
[product brief](../docs/spec/product-brief.md). Root `gateway` / `gateway.cmd`
launchers coordinate configuration, reviewed deployment, identity preparation,
database initialization, workload deployment, and verification.

## Product direction

| Concern | Target |
|---|---|
| Runtime | **Platform-agnostic** — Docker Compose / Kubernetes on AWS, GCP, Azure compute, or on-prem |
| Database | **PostgreSQL** (SQLite optional for local/dev) |
| Messaging | **RabbitMQ** |
| Secrets | **OpenBao** / **HashiCorp Vault** |
| Content | **S3-compatible** object storage |
| Images | Any **OCI** registry |
| UI | React + Fluent Setup (legacy `Gateway.Setup` transitional) |
| Backend | C# API, worker, migrator; optional Windows Purview executor |

**Logic stays intact.** Infrastructure has **zero Microsoft dependence** — no
Azure SQL, Service Bus, Key Vault, Container Apps, ACR, or Blob as requirements.
Existing Azure Bicep/What-If flows are a **legacy infrastructure profile** only.
See [system architecture](../docs/architecture/system-architecture.md) and
[infrastructure](../infrastructure/README.md).

**Essential product services** (wherever containers run): Entra, Graph, Agent 365,
Purview, Prompt Shields.

## Source and target

The installer currently uses the authored [Setup](../tools/Gateway.Setup) UI and
[DatabaseMigrator](../tools/Gateway.DatabaseMigrator) projects. Setup UI is
legacy relative to the React + Fluent target; DatabaseMigrator stays on C# and
targets **PostgreSQL** for the portable profile. Build the production solution
before installation. Generated output does not replace source, and a local build
does not establish deployment or provider readiness.

Select the intended Entra tenant, deploy profile (portable vs legacy Azure), and
environment in configuration. Plan and Apply bind their exact source and target.
An old checkpoint does not authorize recreating a deleted environment.

## Intended installation (guided — do not edit JSON)

Operators must not hand-edit configuration files. Use the guided surfaces:

```powershell
.\gateway.cmd up
```

That launches the **TUI wizard** when `bootstrap/config.json` is missing
(deploy profile → Azure login/subscription → environment → capabilities →
confirm), writes non-secret `bootstrap/config.json`, then plans/applies.

```powershell
.\gateway.cmd init          # wizard only (writes config)
.\gateway.cmd setup         # temporary Fluent GUI Setup host
.\gateway.cmd doctor        # prerequisite check
```

`config.example.json` / `config.example.portable.json` are **schema samples for
developers**, not operator inputs. `gateway` refuses `--config` pointing at
those filenames.

Terminal lifecycle (all profiles):

```text
doctor → init (guided) → plan → apply → verify
                              ↘ resume after an eligible interruption
```

This is a workflow description, not an instruction to resume a deleted
environment. Do not invoke deployment to discover missing build inputs.

## Prerequisites and configuration

Common inputs: Git, the .NET SDK from [global.json](../global.json),
[nuget.config](../nuget.config), PowerShell 7, and **Docker** (portable profile).

| Profile | Extra tools |
|---|---|
| Portable (target) | Docker Engine / Kubernetes toolchain as selected |
| Legacy Azure | Azure CLI; subscription/RBAC as today |

The Purview package contract (when Purview is selected) still requires Windows
x64, Microsoft-signed PowerShell **7.6.5** and ExchangeOnlineManagement **3.10.1**
for the executor package — that is a Microsoft 365 integration constraint, not an
Azure PaaS hosting requirement.

[config.schema.json](config.schema.json) and
[config.example.json](config.example.json) today still describe many Azure-centric
fields for the legacy profile. Portable-profile configuration must express
PostgreSQL, RabbitMQ, Vault/OpenBao, S3, and OCI settings without requiring an
Azure subscription. Passwords, tokens, clear Gateway keys, prompt/response text
and certificate material do not belong in configuration.

Registry provisioning remains a Development-only preview.

### Reviewed manager applications

Review `agent365.reviewedManagerApplicationIds` independently before creating a
blueprint. Verify the current
[Agent 365 CLI authentication constants](https://github.com/microsoft/Agent365-devTools/blob/main/src/Microsoft.Agents.A365.DevTools.Cli/Constants/AuthenticationConstants.cs)
and read back the corresponding service principal in the intended tenant.
Record reviewed non-secret IDs in configuration; tenant eligibility and consent
still require separate validation.

## Deployment responsibilities

### Portable profile (target)

Choose **Portable (recommended)** in the guided wizard (`gateway up` / `gateway init`).

Bootstrap then owns:

- **Entra** app registration, app roles, and administrator assignment (Graph)
- **Optional Azure AI Content Safety** in the selected subscription RG/location
  when you enable Prompt Shields (product API — not gateway host infra)
- **Docker Compose** deploy of PostgreSQL, RabbitMQ, Vault, S3-compatible storage,
  API, Worker, and **React Console** under `deploy/portable/`
- Local image build from the repo Dockerfiles
- Portable Entra workload + API OBO + **blueprint FMI** client secrets (gitignored
  `.env.runtime` / `.bootstrap/secrets/`) so Registry OBO and Active verification
  work without Azure managed identity

Purview Windows executor packaging remains a post-compose Microsoft 365 handoff.
Legacy Container Apps / Azure SQL / Service Bus / Key Vault are **not** required.

```powershell
.\gateway.cmd up
```

Engineer handoff (FMI, consent, gates, rebuild): [docs/portable](../docs/portable/README.md).

### Legacy Azure profile (transitional)

Existing assets may still provision Container Apps, ACR, Azure SQL, Service Bus,
Blob, Key Vault, managed identities, Application Insights, and Windows App Service
for Purview. Treat as legacy only. Detailed Azure What-If / MFA / ACR behaviors
below apply to that profile, not to portable Compose/Kubernetes installs.

Bootstrap prepares capabilities. The hosted UI owns tenant connection, SIT
inventory, KYD/DLP configuration, and runtime verification after install. An
installed capability is not an authored policy or a proven allow/block result.

The Entra automation identity is not its Security & Compliance service-principal
reference. Before the first Purview tenant connection, follow the
[provider-reference prerequisite](../operations/README.md#purview-automation-reference-prerequisite).

## Command reference

| Command | Intended boundary |
|---|---|
| `setup` | Local setup UI; not a claim of deployed resources |
| `init` | Create non-secret configuration |
| `doctor` | Check tools, configuration and provider readiness |
| `plan` | Validate inputs; portable: manifest/plan dry-run; legacy Azure: Bicep What-If |
| `apply` / `up` | Execute a matching accepted plan |
| `resume` | Continue eligible work for the same accepted deployment |
| `status` | Inspect local operational checkpoint/readiness state |
| `verify` | Read back the live deployment boundary |
| `open` | Open the recorded verified hosted UI endpoint |
| `diagnose` | Write a sanitized local diagnostic bundle |

Use `gateway.cmd` on Windows. Bootstrap has no general destroy or Registry-replay
command. See [operator workflows](../operations/README.md).

## Plan, state and recovery

Plan binds exact source, configuration, target, and profile-specific dry-run
results. Apply rechecks that binding before mutation. Unknown outcomes require
bounded readback, not a repeated create. Never edit checkpoints to manufacture
success.

Ignored `.bootstrap/` state supports safe reconciliation. It records non-secret
resource, identity, image and source identifiers.

### Legacy Azure profile notes

The following apply when using the transitional Azure PaaS profile only:

- Plan may compile Bicep and run authenticated What-If.
- Deployment identity may include subscription, tenant, environment, location,
  project name and resource group.
- Azure resource-management MFA can reject What-If; complete MFA then rerun Plan
  or use Resume — do not bypass MFA or recreate resources to work around it.
- Image builds may target ACR; uncertain submitted builds are not auto-repeated.
- Ingress trusted-proxy CIDRs may follow the former Container Apps contract; the
  portable profile uses the actual reverse-proxy/LB CIDRs instead. See
  [API HTTPS contract](../docs/api/api-contract.md#https-ingress).
- Deleting a resource group does not prove tenant objects were deleted.

Portable profiles use Compose/Kubernetes apply semantics and Vault/DB/Rabbit
readback instead of Azure What-If.

## After a verified installation

**Portable:** open the React Console (default `http://127.0.0.1:5081`), sign in,
register → one-time key → **Finish Agent 365 registration** (signed-in admin) →
wait for **Active**. Details:
[portable handoff](../docs/portable/README.md).

**Legacy Azure:** hosted UI may still be Blazor Admin UI until cutover; same
registration → key → Registry → optional protection contract.

Intentionally Off per-agent protections are not an incomplete registration. Keep
policy readback, propagation and runtime evidence separate.

See [connect an agent](../README.md#connect-an-external-agent),
[API contract](../docs/api/api-contract.md),
[Purview executor](../docs/architecture/purview-windows-executor.md),
[portable runtime](../deploy/portable/README.md), and
[infrastructure](../infrastructure/README.md).
