# A365 Custom Gateway

A365 Custom Gateway gives external agents one controlled path into Microsoft Agent
365. An administrator deploys the Gateway, registers an external agent against a
reusable Agent ID blueprint, and receives a Gateway external ID plus a one-time
ingress key. The agent then submits activity and interaction data through the
Gateway API without receiving an Entra token or managed-identity identifier.

Version `0.1.0-beta.2` is a prerelease source contract, not proof that this checkout
is deployed. The current source is ahead of the deployment evidence recorded in
[development deployment status](docs/operations/development-deployment-status.md),
and a Purview DLP allow/block pair has not been live-proven on a deployed build.

> **Implemented in source, not deployed:** bootstrap installs deployment
> capabilities only. Prompt Shields defaults and per-agent use, plus Purview tenant
> connection, sensitive-information-type selection, Know Your Data, blueprint DLP,
> readiness, and ongoing changes are in role-aware Gateway Admin Settings. Final
> backend acceptance failed and reopened the beta.2 candidate for four corrections:
> runtime identity correctness, exact capability/runtime binding, cancellation
> cleanup, and truthful updates of existing KYD/DLP policy. Prior final gates are
> invalidated. The clean-deployment E2E remains postponed and requires fresh
> exact-target authority.

The supported fresh-subscription installer is the repository-root `gateway`
launcher. It configures, plans, deploys, and verifies the complete Gateway. The
terminal launcher also supports checkpoint-aware Resume. A restarted Setup browser
process implements the same read-only review and separate confirmation, but that
browser path has not yet been validated against preserved stopped state; use the
terminal recovery command described below.

> The Agent 365 Registry dependency is currently a beta capability that Microsoft
> does not support for production use. **Quick development** defaults this
> deployment-wide capability on but requires explicit beta acknowledgement.
> Staging and production remain closed.

## Quick start

You need an Agent-365-enabled Microsoft Entra tenant, an Azure subscription, and an
administrator who can approve the Azure, Entra, and Agent ID changes shown by the
installer. On the workstation, install Git, the .NET 10 SDK, PowerShell 7, and Azure
CLI 2.76 or later.

Core Gateway setup and deployment run on Windows, macOS, and Linux. Bootstrap
prepares optional Purview identities, RBAC, certificate, Key Vault, dedicated
administration queue, and runtime prerequisites without choosing a classifier or
authoring policy.
Security & Compliance PowerShell operations that still require
`Connect-IPPSSession` remain interactive and Windows-only; Gateway Settings
coordinates those operations through a bounded, downloadable Windows companion.

```bash
git clone https://github.com/patrick-shim/a365-custom-gateway.git
cd a365-custom-gateway
az login
./gateway setup
```

On Windows, use `.\gateway.cmd setup` instead. Setup opens a temporary browser UI on
`127.0.0.1`, discovers the subscriptions visible to the current Azure CLI session,
and loads the selected subscription's physical Azure regions into a dropdown. The
dropdown shows the friendly label and exact Azure name together—for example,
`Korea Central · koreacentral`—and stores only the canonical name. Setup writes the
reviewed non-secret `bootstrap/config.json`, proves the configured Azure SQL tier is
available in the selected region, runs an authenticated Azure What-If plan, and
waits for explicit confirmation before deployment. Complete any Microsoft sign-in
or consent windows that open during setup or deployment.

Setup offers three capability presets. **Full evaluation** is selected by default
for Quick development and includes Agent 365 Registry beta, Prompt Shields
infrastructure, and Purview prerequisites; each applicable beta, cost/quota, and
authority acknowledgement is explicit. **Core Gateway** omits Prompt Shields and
Purview. **Custom** selects those two independently. Registry beta remains closed
outside development.

```mermaid
flowchart LR
    clone[Clone repository] --> signin[Azure CLI sign-in]
    signin --> setup[Gateway Setup]
    setup --> plan[Review configuration and What-If]
    plan --> deploy[Confirm and deploy]
    deploy --> verify[Automatic verification]
    verify --> admin[Sign in to Admin UI]
    admin --> settings[Configure optional protections]
    settings --> register[Register external agent]
    register --> active[Registration Active]
    active --> use[Send through Gateway API]
```

For a terminal-only installation, run:

```bash
./gateway doctor
./gateway init
./gateway plan
./gateway apply --open
```

`doctor` and `plan` fail before resource creation if the configured Azure SQL
edition, service objective, 2 GiB size, or LRS storage path cannot be proven
available in the selected region. `plan` records a time-bounded acceptance of the
exact configuration, source, and What-If result. `apply` revalidates that acceptance
before changing anything. If an interruption occurs, correct the reported cause and
run `./gateway resume` on macOS/Linux or `.\gateway.cmd resume` on Windows; do not
delete `.bootstrap/` or start a second deployment.
Terminal Resume is the supported recovery path after Setup has closed or restarted.
The Setup browser's separate read-only Resume review and second confirmation are
implemented and covered by local tests, but are not an end-to-end recovery claim
until validated in a browser against preserved stopped state.

See the [bootstrap guide](bootstrap/README.md) for prerequisites, configuration,
automation, and recovery behavior.

## Sign in and register an agent

After verification, Setup shows the Admin UI and API endpoints. You can reopen the
recorded Admin UI later with:

```bash
./gateway open
```

Sign in with a user assigned the `Gateway.Administrator` app role, then use the
Admin UI to:

1. Select or create a reusable Agent ID blueprint.
2. Choose the registration's observability and optional protection settings.
3. Submit the registration and complete the administrator handoff when prompted.
4. Wait until the Gateway reports the registration as `Active`.
5. Copy the external agent ID and one-time Gateway key to the external agent's
   secret store. The clear key is not shown again.

The Gateway creates a distinct child Entra Agent ID for every registration. A
registration remains bound to its stored registration record, selected blueprint,
child Agent ID, external ID, and key lifecycle.

## Send a sample interaction

Use the API base URL and external agent ID shown by the Admin UI. The sample reads
the one-time Gateway key from a non-echoing prompt; never place the key on the
command line.

```bash
dotnet run --project src/ExternalAgent.Sample -- \
  --api-base-url https://YOUR-GATEWAY-API/ \
  --external-agent-id YOUR-EXTERNAL-AGENT-ID \
  --tenant-user-object-id YOUR-USER-OBJECT-ID \
  --message "Hello through the Gateway"
```

The sample evaluates the prompt, submits Agent 365 activity/OTel data, and submits
the completed prompt/response interaction. A successful run prints only safe
decisions and correlation identifiers; it does not print provider response bodies
or the Gateway key.

The complete HTTP contract is in [OpenAPI](docs/api/openapi.yaml).

## Optional runtime protections

Agent 365 observability is enabled by default for a registration. Azure Monitor
mirroring, Prompt Shields, and Microsoft Purview are separate choices.

| Capability | Default | What it does |
|---|---:|---|
| Agent 365 observability | On | Submits registration-scoped activities to Agent 365. |
| Azure Monitor mirror | Off | Mirrors selected telemetry to the Gateway's Azure Monitor path. |
| Prompt Shields | Off | Evaluates prompts before protected interaction ingestion by using Azure AI Content Safety with managed identity. |
| Microsoft Purview | Off | Evaluates configured activities and attributes them to the child Agent ID and reusable blueprint after its exact DLP profile is Ready. |

Bootstrap capability and Gateway configuration are different facts. Prompt Shields
requires bootstrap-provisioned Azure AI Content Safety and RBAC, while its default
and per-agent enablement belong in Settings. Purview bootstrap prepares only
identity, RBAC, certificate, Key Vault, dedicated queue, and runtime prerequisites.
A signed-in Administrator then uses Settings for tenant connection, SIT selection,
KYD, blueprint profiles/rules, propagation/readiness, and ongoing changes. Settings
keeps capability readback, policy readback, propagation, token roles, and runtime
allow/block evidence separate.

Purview policy provisioning uses two different Microsoft location contracts and
must not combine them:

- Know Your Data collection: the fixed tenant-wide enterprise-AI-apps location
  `ee1680d0-702f-4090-b26c-c49091e86531`, with `LocationType=Group` on the
  Application plane.
- DLP policy: the selected reusable blueprint application/client ID, with
  `LocationType=Individual` on the Application plane.

The [Purview runbook](docs/operations/purview-setup-runbook.md) describes the current
transition and the target role-aware flow. Policy readback does not prove token-role
propagation or a data-plane verdict, and no registration uses Purview unless an
administrator explicitly enables it after the exact blueprint profile is Ready.

## Architecture

```mermaid
flowchart TB
    admin[Gateway Administrator] --> ui[Blazor Admin UI]
    ui -->|Entra user token| api[Gateway API]
    client[External agent] -->|External ID + Gateway key| api
    api --> sql[(Azure SQL)]
    api --> blob[(Encrypted Blob storage)]
    sql --> relay[Transactional outbox relay]
    relay --> bus[Service Bus gateway-provisioning-v3]
    relay --> pbus[Service Bus gateway-protection-admin-v1]
    bus --> worker[Provisioning worker]
    pbus --> worker
    worker --> sql
    worker --> entra[Microsoft Entra Agent ID]
    worker --> a365[Agent 365]
    api -. optional .-> shield[Azure AI Content Safety]
    api -. optional .-> purview[Microsoft Purview]
    api --> monitor[Application Insights / Azure Monitor]
```

The API is the authorization boundary. UI role checks improve usability but do not
replace API enforcement. Work is persisted in SQL and Service Bus so deployment and
provisioning can reconcile after interruption without assuming exactly-once
delivery.

## Operate an existing deployment

These commands are safe entry points from the repository root:

The table uses the macOS/Linux launcher. On Windows, replace `./gateway` with
`.\gateway.cmd`.

| Command | Purpose |
|---|---|
| `./gateway status` | Show local checkpoint/readiness state without Azure calls. |
| `./gateway verify` | Rerun read-only live deployment verification. |
| `./gateway resume` | Reconcile and continue an interrupted accepted deployment. |
| `./gateway diagnose` | Write a sanitized diagnostic bundle, including when configuration cannot load. |
| `./gateway open` | Open the recorded verified Admin UI endpoint. |

`verify` performs live provider reads, and `resume` can mutate the recorded target.
Before either action, confirm current authority for that exact tenant, subscription,
resource group, and operation; a prior deployment approval does not carry forward.

Use [operations](operations/README.md) for an existing environment and
[infrastructure](infrastructure/README.md) for the declarative asset map. The
bootstrap intentionally has no destroy, Registry replay, retained-message, or
cleanup command.

## Documentation

- [Documentation hub](docs/README.md)
- [Bootstrap and configuration](bootstrap/README.md)
- [Admin UI guide](docs/agent-guides/admin-ui.md)
- [Provisioning guide](docs/agent-guides/provisioning.md)
- [System architecture](docs/architecture/system-architecture.md)
- [Protection settings plan](docs/architecture/protection-settings-plan.md)
- [Backup and recovery](docs/operations/backup-recovery.md)
- [Incident response](docs/operations/incident-response.md)
- [Contributor continuation checkpoint](docs/agent-continuation.md)

Current implementation and deployment evidence lives in
[implementation status](docs/implementation-status.md) and
[development deployment status](docs/operations/development-deployment-status.md).
Those files are engineering checkpoints, not installation instructions.
