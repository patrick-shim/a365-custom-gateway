# A365 Custom Gateway — product brief

Canonical statement of **objective**, **scope**, **features**, **platforms**
(UI + runtime), and **expected behavior**. Implementation details live in
architecture and API docs; install steps live in the project README and bootstrap
guide.

## Objective

Give a Microsoft 365 tenant one control plane to connect **independently hosted**
AI agents to the Microsoft services that are this product's **sole purpose**:

- **Microsoft Entra** (operator auth, app roles, workload app registrations)
- **Microsoft Graph** (Agent Identity blueprints, child Agent IDs, federation)
- **Microsoft Agent 365** (Registry, observability)
- **Microsoft Purview** (tenant connection, DLP, KYD, runtime evidence)
- **Prompt Shields** (prompt-attack evaluation via Microsoft content safety)

External agents keep their own hosting and model calls. The Gateway owns
installing that control plane, registration, one-time ingress keys, Registry
handoff, evaluate/ingest receipts, and protection administration.

**Critical split:** those Microsoft **cloud services** are essential product
dependencies. The Gateway **running environment** (database, queues, secrets,
object storage, containers) must have **zero Microsoft / Azure infrastructure
dependence** — pack the images onto **AWS** (ECS/EKS), **GCP**, other container
platforms, or on-prem Docker/Kubernetes and it should just work.

Ordinary external agents never manage Entra credentials.

## Two layers (non-negotiable)

| Layer | Microsoft dependence | Examples |
|---|---|---|
| **Product services** (why the Gateway exists) | **Required** — Entra, Graph, Agent 365, Purview, Prompt Shields | Call Microsoft APIs with tenant credentials |
| **Infrastructure** (where the Gateway runs) | **Zero** — no Azure SQL, Service Bus, Key Vault, Container Apps, ACR, Blob, Managed Identity, App Insights as requirements | PostgreSQL, RabbitMQ, Vault/OpenBao, S3/MinIO, OCI images, Compose/K8s |

Per-agent toggles (e.g. Prompt Shields On/Off for one registration) do not make
Purview or Prompt Shields "non-essential" to the product. Infrastructure choices
must never force an Azure subscription.

## Platform requirements

These are product requirements, not suggestions.

### A. Application platform

| Layer | Requirement |
|---|---|
| **Backend** | Remain on **C# / .NET** — Gateway API, provisioning worker, Windows Purview executor, database migrator |
| **Installer engine** | Guided bootstrap (`gateway` / `gateway.cmd`) deploys **non-Microsoft infrastructure** (Docker Compose / Kubernetes) |
| **All user interfaces** | Modernize completely to **React + TypeScript + Fluent UI v9** — Console **and** Setup |

Authoritative UI direction: [UI design system](../console/design.md).

### B. Infrastructure (zero Microsoft dependence)

Gateway **logic** stays intact. The **running environment** uses only open-source
/ portable building blocks. Taking the same containers to AWS, GCP, or on-prem
must not require any Microsoft-hosted infrastructure service.

| Concern | Target (required direction) | Forbidden as a requirement |
|---|---|---|
| Durable state | **PostgreSQL** (primary); **SQLite** for single-node local/dev | Azure SQL |
| Messaging / queues | **RabbitMQ** (AMQP); same outbox + queue contracts | Azure Service Bus |
| Secrets | **OpenBao** or **HashiCorp Vault** | Azure Key Vault |
| Object / content store | **S3-compatible** (**MinIO** or cloud S3/GCS via S3 API) | Azure Blob as a requirement |
| Compute | **Docker Compose** and/or **Kubernetes** (ECS/EKS/GKE/AKS/on-prem) | Azure Container Apps as a requirement |
| Container images | Any **OCI** registry (ECR, GCR, GHCR, Harbor, …) | ACR as a requirement |
| Workload credentials to infra | Vault / K8s projected SA / non-Microsoft cloud WI | Azure Managed Identity for DB/bus/secrets |
| Local ops telemetry | **OpenTelemetry** to operator backends | Azure Monitor / App Insights as a requirement |
| Ingress TLS | Standard reverse proxy / cloud LB | Container Apps ingress as a requirement |

Legacy Azure PaaS templates in the repo are transitional only — not the product
end state.

### C. Essential Microsoft product services (not infrastructure)

These are **required** for the Gateway's purpose. They are SaaS/API integrations,
not the place the Gateway runs:

| Service | Role |
|---|---|
| **Entra ID** | Operator sign-in, roles, app registrations |
| **Microsoft Graph** | Blueprints, child Agent IDs, federation |
| **Agent 365** | Registry completion, observability export |
| **Purview** | Connection, SITs, DLP, KYD, runtime tests (Windows executor when used) |
| **Prompt Shields** | Pre-model prompt-attack evaluation (Microsoft content safety API) |

A portable AWS/GCP/on-prem deploy still needs a Microsoft 365 / Entra tenant and
credentials for these APIs. It must **not** need Azure SQL, Service Bus, Key Vault,
or other Azure infrastructure.

### D. What must not become permanent

- Any Microsoft-hosted infrastructure as a hard runtime requirement
- Rewriting the C# control plane into another language
- Keeping Blazor or the legacy Setup UI as long-term UX
- Claiming infrastructure portability removes Entra / Graph / Agent 365 / Purview / Prompt Shields

### Migration status (current vs target)

| Area | Today (legacy) | Target |
|---|---|---|
| Hosted UI | Blazor Admin UI | React + Fluent Console |
| Setup UI | `Gateway.Setup` | React + Fluent Setup |
| Infrastructure | Azure Bicep + Azure PaaS | Compose/Kubernetes + PostgreSQL/RabbitMQ/Vault/S3 — **zero Microsoft infra** |
| Product services | Entra, Graph, Agent 365, Purview, Prompt Shields | **Unchanged — still essential** |

Code and Azure templates may still implement the legacy infra profile until cutover.

## Scope

### In scope

| Area | What the product does |
|---|---|
| Install | Guided bootstrap deploys API, worker, hosted UI, PostgreSQL, RabbitMQ, Vault/OpenBao, S3-compatible storage (portable profile) |
| Identity | Map each registration to one reusable blueprint and one distinct child Agent ID |
| Credentials | Issue, replace, and revoke Gateway keys (not Microsoft identity credentials) |
| Registry | One delegated Registry create per lineage, then Gateway verification to Active |
| Data plane | Authenticate by Gateway key; evaluate prompts; accept activities and AI interactions |
| Telemetry | Export sanitized activity to Agent 365 observability; optional OpenTelemetry ops mirror |
| Prompt Shields | Essential product capability — prompt-attack evaluation (per-agent On/Off remains) |
| Purview | Essential product capability — connection, SITs, DLP, KYD, runtime tests |
| Operate | Health, roles, audit history, enable/disable, retry provisioning, upgrade tooling |
| UI platform | Complete React + Fluent modernization of all Gateway UIs |
| Infrastructure | Zero Microsoft dependence — AWS/GCP/on-prem containers just work |

### Out of scope

- Proxying or hosting the external model call
- Claiming response-side blocking when Microsoft returns offline processing
- Treating Agent 365 Registry beta as a staging/production-supported path
- Deleting linked Microsoft identities or policies when a Gateway registration is removed
- Treating deploy health, a saved policy, simulation, or a historical Completed
  operation as proof of current enforcement or telemetry delivery
- Rewriting the C# control plane, worker, or Windows Purview executor into Node/another backend
- Keeping Blazor, legacy Setup UI, or **any Microsoft infrastructure** as required runtime
- Replacing Entra / Graph / Agent 365 / Purview / Prompt Shields with non-Microsoft
  substitutes while still claiming this Gateway's purpose
- Requiring Azure SQL, Service Bus, Key Vault, Container Apps, ACR, or Blob to run

## Audiences and outcomes

| Audience | Outcome |
|---|---|
| **Administrator** | Install Gateway on chosen runtime → register agent → store key → complete Registry handoff → wait for Active → configure optional protection |
| **Operator** | Inspect health and operations; enable/disable access; see what needs an administrator |
| **Auditor / Support reader** | Read audit and permitted registration/capability state |
| **External developer** | Integrate one registration via external ID + Gateway key (no operator UI required) |

Administrator happy path:

1. Clone the repository and run guided setup (`gateway` / `gateway.cmd`).
2. Choose a **portable** deploy target (Compose/Kubernetes on chosen cloud or on-prem).
3. Review Entra/Microsoft 365 permissions and optional capabilities in the Setup UI.
4. Deploy a verified Gateway and open the hosted Console / Admin UI.
5. Register an agent on a new or compatible existing blueprint.
6. Securely store the API endpoint, external agent ID, and one-time Gateway key.
7. Complete the signed-in Administrator Registry handoff; wait for worker verification.
8. Point the external agent at evaluate → model → ingest with the evaluation receipt.

## Requested features

### Core (required for a useful registration)

1. **Guided install** — doctor → init → plan → apply → verify on a portable profile.
2. **Agent registration** — create/list/get; blueprint selection; provisioning tracking.
3. **Gateway credentials** — one-time handoff; replace; revoke; runtime readiness check.
4. **Lifecycle controls** — enable/disable; retry provisioning; delete Gateway registration only.
5. **Registry completion** — delegated `CompleteAgent365Registration`; exact-ID recovery.
6. **Prompt evaluation** — `POST /api/v1/prompts:evaluate` before the model.
7. **Intake** — activities and AI interactions with receipt rules unchanged.
8. **System surfaces** — `/system/config`, health/ready, audit events, role enforcement.
9. **Modern UI** — React + Fluent Console and Setup.
10. **Portable runtime** — PostgreSQL, RabbitMQ, Vault/OpenBao, S3-compatible store, OCI images.

### Essential Microsoft product capabilities

| Feature | Purpose | Notes |
|---|---|---|
| Agent 365 observability | Registration-scoped sanitized activity export | Default product telemetry destination |
| Prompt Shields | Prompt-attack evaluation (Microsoft content safety) | Essential product service; per-agent On/Off is a usage control |
| Purview connection / SITs / DLP / KYD | Tenant protection administration | Essential product service; modes include Disabled / Simulation / Enforce |

### Non-Microsoft ops extras

| Feature | Purpose | Notes |
|---|---|---|
| OpenTelemetry mirror | Sanitized monitoring to operator backends | Infrastructure telemetry — not a Microsoft hosting dependency |

A registration may run with Prompt Shields or Purview usage Off; the Gateway
product must still ship and support those Microsoft services.

### Protection administration shape

Mutations use **review → confirm → start** (HTTP 202 queued work). Reads use
ETags / row versions. Unknown provider outcomes fail closed and recover by exact
readback, never by a second create. Queue transport is RabbitMQ (target) with the
same logical queue names/contracts as today's Service Bus queues.

### Registration vs protection (API vs Console IA)

- **API / legacy Admin UI:** registration may include optional feature/protection choices.
- **Target Console IA:** registration is name → blueprint → key; Prompt Shields on
  the agent; DLP/SITs under Data protection.

## Expected behaviors

Unchanged product contracts (credentials, Registry preview, data plane, protection,
authorization) remain as before — only the **hosting dependencies** change.

### Credentials and registration

- Gateway key shown **once**; salted verifier only in storage.
- Lost key → **replace**, not re-register.
- Uncertain create → **exact-ID readback**, never a second create.
- Delete Gateway registration **preserves** linked Microsoft resources.
- Blueprints (and Purview DLP) are **shared**; each registration has its own child identity and key.
- **Active** ≠ optional protection or telemetry ready.

### Registry preview

- Beta API; **Development-only** with explicit acknowledgement.
- Staging/production admission **closed** in source.
- Worker never creates Registry entry; Administrator does.
- HTTP 200 on completion queues verification ≠ Active.

### Data plane

- Auth: external agent ID + Gateway key.
- Evaluate before model; allow receipt short-lived, single-use, context-bound.
- HTTP **202** = accepted/queued, not delivered/enforced.
- Simulation ≠ enforcement readiness.

### Protection and telemetry

- Prompt Shields and Purview independent; requested ≠ effective.
- Saved policy / simulation / historical Completed ≠ current enforcement.
- Local OTel/Agent 365 span acceptance ≠ proof of every downstream destination.

### Authorization

- Control plane: Entra bearer + `access_as_user` + Gateway roles.
- UI role visibility never replaces API authorization.
- Fail closed on missing/stale/unknown required provider proof.

## Quality attributes (non-negotiable)

- Least-privilege workload credentials and delegated user access.
- No secrets, tokens, prompts, responses, or provider bodies in logs, queues, or checkpoints; interaction content in the protected object store.
- Durable relational workflow state + transactional outbox; duplicate-safe queue consumers (RabbitMQ target).
- Discover-before-create provider operations; one Registry POST with exact-ID recovery.
- RFC 9457 Problem Details with safe correlation IDs.
- Resumable bootstrap checkpoints; maintenance/upgrade is a separate authorized lifecycle.
- React + Fluent for all UIs; C# backend.
- **Infrastructure: zero Microsoft dependence** (PostgreSQL, RabbitMQ, Vault/OpenBao, S3, Compose/K8s).
- **Product services: Entra, Graph, Agent 365, Purview, Prompt Shields remain essential.**

## Where to go next

| Need | Document |
|---|---|
| Build, install, sample client | [Project README](../../README.md) |
| Components and portable runtime | [System architecture](../architecture/system-architecture.md) |
| HTTP rules and lifecycle | [API contract](../api/api-contract.md) · [OpenAPI](../api/openapi.yaml) |
| Protection ownership and proof | [Protection architecture](../architecture/protection-settings-plan.md) |
| UI platform | [UI design](../console/design.md) |
| Installer / profiles | [Bootstrap](../../bootstrap/README.md) |
| Operations | [Operations](../../operations/README.md) |
