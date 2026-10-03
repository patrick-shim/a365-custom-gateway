# A365 Custom Gateway — product brief

Canonical statement of **objective**, **scope**, **features**, **UI platform**,
and **expected behavior**. Implementation details live in architecture and API
docs; install steps live in the project README and bootstrap guide.

## Objective

Give a Microsoft 365 / Azure tenant one control plane to connect **independently
hosted** AI agents to **Microsoft Agent 365** identity and observability, with
**optional** Prompt Shields and Microsoft Purview protection.

External agents keep their own hosting and model calls. The Gateway owns:

- installation of the tenant-owned Azure control plane;
- registration against reusable Agent Identity blueprints;
- one-time Gateway ingress credentials;
- delegated Agent 365 Registry completion (development preview);
- pre-model prompt evaluation receipts and post-interaction intake;
- optional protection administration and runtime evidence.

It serves organizations that own Azure and Microsoft 365 but run agents outside
Microsoft hosting. Ordinary external agents never manage Entra credentials.

## Platform requirement (UI and backend)

This is a product requirement, not a suggestion.

| Layer | Requirement |
|---|---|
| **Backend** | Remain on **C# / .NET** — Gateway API, provisioning worker, Windows Purview executor, database migrator, and related services |
| **Installer engine** | Remain on the PowerShell bootstrap orchestration (`gateway` / `gateway.cmd`) |
| **All user interfaces** | Modernize **completely** to one reactive web stack — **including Admin/Console and guided Setup/bootstrap UI** |

### Target UI stack (all Gateway UIs)

| Concern | Choice |
|---|---|
| Language | TypeScript (strict) |
| UI library | React (function components + hooks) |
| Build | Vite |
| Design system | Fluent UI React v9 — sleek, Microsoft-native, accessible |
| Server state | TanStack Query — reactive cache/revalidation |
| Routing | React Router |
| Auth (hosted Console) | MSAL React (Entra OIDC + delegated API bearer) |
| Qualities | Fully reactive, fast, responsive, flexible; plain short copy; one job per page |

No new Blazor/Razor UI. No long-term dual UI families. Blazor Admin UI and the
current Setup UI are **legacy surfaces to replace**, not permanent product UX.

Authoritative UI direction: [UI design system](../console/design.md).

### UI migration status (current vs target)

| Surface | Today (legacy) | Target |
|---|---|---|
| Hosted operator UI | Blazor Admin UI deployed by bootstrap | React + Fluent Console on the same `/api/v1` |
| Guided install UI | `tools/Gateway.Setup` (current Setup app) | React + Fluent Setup experience; same bootstrap plan/apply/verify engine underneath |
| External developer | No UI required | Unchanged — API + sample client |

Until cutover completes, docs may describe legacy Blazor/Setup behavior for what
is still deployed. That is transitional truth, not the end state.

## Scope

### In scope

| Area | What the product does |
|---|---|
| Install | Guided bootstrap deploys API, provisioning worker, hosted UI, SQL, Service Bus, Key Vault, and related Azure assets |
| Identity | Map each registration to one reusable blueprint and one distinct child Agent ID |
| Credentials | Issue, replace, and revoke Gateway keys (not Microsoft identity credentials) |
| Registry | One delegated Registry create per lineage, then Gateway verification to Active |
| Data plane | Authenticate by Gateway key; evaluate prompts; accept activities and AI interactions |
| Telemetry | Export sanitized activity to Agent 365 observability; optional Azure Monitor mirror |
| Prompt Shields | Optional Azure AI Content Safety evaluation before the external model call |
| Purview | Optional tenant connection, SIT inventory, blueprint DLP, KYD Group, runtime tests |
| Operate | Health, roles, audit history, enable/disable, retry provisioning, upgrade tooling |
| UI platform | Complete React + Fluent modernization of **all** Gateway UIs, including bootstrap Setup |

### Out of scope

- Proxying or hosting the external model call
- Claiming response-side blocking when Microsoft returns offline processing
- Treating Agent 365 Registry beta as a staging/production-supported path
- Deleting linked Microsoft identities or policies when a Gateway registration is removed
- Treating deploy health, a saved policy, simulation, or a historical Completed
  operation as proof of current enforcement or telemetry delivery
- Rewriting the C# control plane, worker, or Windows Purview executor into Node/another backend
- Keeping Blazor or the legacy Setup UI as the long-term product experience

## Audiences and outcomes

| Audience | Outcome |
|---|---|
| **Administrator** | Install Gateway → register agent → store key → complete Registry handoff → wait for Active → configure optional protection |
| **Operator** | Inspect health and operations; enable/disable access; see what needs an administrator |
| **Auditor / Support reader** | Read audit and permitted registration/capability state |
| **External developer** | Integrate one registration via external ID + Gateway key (no operator UI required) |

Administrator happy path:

1. Clone the repository and run guided setup (`gateway` / `gateway.cmd`).
2. Review tenant, subscription, permissions, and optional capabilities in the Setup UI.
3. Deploy a verified Gateway and open the hosted Console / Admin UI.
4. Register an agent on a new or compatible existing blueprint.
5. Securely store the API endpoint, external agent ID, and one-time Gateway key.
6. Complete the signed-in Administrator Registry handoff; wait for worker verification.
7. Point the external agent at evaluate → model → ingest with the evaluation receipt.

## Requested features

### Core (required for a useful registration)

1. **Guided install** — doctor → init → plan → apply → verify (resume when eligible), with a modern Setup UI.
2. **Agent registration** — create/list/get; blueprint selection; provisioning operation tracking.
3. **Gateway credentials** — one-time handoff; replace; revoke; runtime readiness check.
4. **Lifecycle controls** — enable/disable; retry provisioning; delete Gateway registration only.
5. **Registry completion** — delegated `CompleteAgent365Registration`; exact-ID recovery.
6. **Prompt evaluation** — `POST /api/v1/prompts:evaluate` before the model.
7. **Intake** — activities (single/batch) and AI interactions that consume a matching allow receipt when protection requires it.
8. **System surfaces** — `/system/config`, health/ready, audit events, role enforcement.
9. **Modern UI platform** — React + Fluent Console and Setup replacing all legacy UIs.

### Optional (independently selectable)

| Feature | Purpose | Notes |
|---|---|---|
| Agent 365 observability | Registration-scoped sanitized activity export | Default telemetry destination |
| Azure Monitor mirror | Sanitized monitoring telemetry | Independent of Agent 365 export |
| Prompt Shields | Prompt-attack evaluation via Content Safety | Per-agent On/Off; shared resource from fresh setup |
| Purview connection | Verify Gateway automation access to the tenant | Gateway verification mode on modern Console |
| Purview SITs | Classifier inventory for policy editing | Inventory expires; refresh needs verified connection |
| Purview DLP | Shared policy on a blueprint (Individual scope) | Modes: Enforce, SimulationWithTips, SimulationWithoutTips, Disabled |
| Know Your Data | Fixed tenant-wide Group collection contract | Separate from blueprint DLP |

Both Prompt Shields and Purview Off is a complete core registration. Requested On
defaults are not silently rewritten when prerequisites are missing.

### Protection administration shape

Mutations use **review → confirm → start** (HTTP 202 queued work). Reads use
ETags / row versions. Unknown provider outcomes fail closed and recover by exact
readback, never by a second create.

### Registration vs protection (API vs Console IA)

- **API / legacy Admin UI:** registration may include optional feature and
  protection choices before dispatch.
- **Target Console IA:** registration is name → blueprint → one-time key;
  Prompt Shields live on the agent; DLP/SITs live under Data protection.
  Optional choices remain available after registration without blocking key handoff.

## Expected behaviors

These are product contracts, not suggestions.

### Credentials and registration

- The Gateway key clear value is shown **once**; storage keeps only a salted verifier.
- A lost key requires **replacement**, not another registration.
- Uncertain create/provider responses require **exact-ID readback**, never a second create.
- Removing a Gateway registration **preserves** linked Microsoft identities and external resources.
- Blueprints (and their Purview DLP) are **shared**; each registration still has its own child identity and key.
- **Active** means Gateway verification of the registration path completed — not that optional protection or telemetry delivery is ready.

### Registry preview

- Registry integration uses the **beta** API and admits only **explicitly acknowledged Development** use.
- Staging and production Registry admission remain **closed** in source.
- The worker never creates the Registry entry; the signed-in Administrator does.
- HTTP 200 on Registry completion queues verification; it does **not** mean Active.

### Data plane

- External callers authenticate with **external agent ID + Gateway key**.
- Callers must **evaluate every prompt before** calling their model when using the supported sample contract.
- An allow receipt is short-lived, single-use, and bound to registration, interaction, user, content type, prompt hash, and current protection context.
- Ingestion consumes the receipt once and rechecks current protection context.
- HTTP **202** means accepted for processing, not delivered or enforced.
- A protection change during generation can reject ingestion; it cannot stop a model call already in flight.
- Simulation modes do not establish enforcement readiness.

### Protection and telemetry

- Prompt Shields and Purview are independent.
- Requested vs effective Prompt Shields state are distinct.
- Enable/disable of a registration is not a Prompt Shields toggle.
- Saved policy, simulation result, or historical Completed operation ≠ current enforcement.
- Expired or changed evidence invalidates readiness labels.
- Agent 365 or Azure Monitor acceptance of a local span ≠ proof of every downstream Microsoft destination.

### Authorization

- Control plane: Entra bearer + `access_as_user` + Gateway roles (`Administrator`, `Operator`, `Auditor`, `SupportReader`).
- Registration create, credentials, deletion, Registry completion, and protection mutations require **Administrator** (operators may enable/disable and read operations).
- UI role visibility never replaces API authorization.
- Fail closed on missing, stale, or unknown required provider proof.

## Quality attributes (non-negotiable)

- Least-privilege managed identity and delegated user access; Entra-only SQL auth.
- No secrets, tokens, prompts, responses, or provider bodies in logs, queues, or operational checkpoints; interaction content stays in the protected content store.
- Durable SQL workflow state + transactional outbox; duplicate-safe Service Bus handling.
- Discover-before-create provider operations; one Registry POST with exact-ID recovery.
- RFC 9457 Problem Details with safe correlation IDs.
- Resumable bootstrap checkpoints; maintenance/upgrade is a separate authorized lifecycle.
- All Gateway UIs converge on the React + Fluent stack above; backend remains C#.

## Where to go next

| Need | Document |
|---|---|
| Build, install, sample client | [Project README](../../README.md) |
| Components and workflows | [System architecture](../architecture/system-architecture.md) |
| HTTP rules and lifecycle | [API contract](../api/api-contract.md) · [OpenAPI](../api/openapi.yaml) |
| Protection ownership and proof | [Protection architecture](../architecture/protection-settings-plan.md) |
| UI platform and design system | [UI design](../console/design.md) |
| Installer details | [Bootstrap](../../bootstrap/README.md) |
| Existing installation ops | [Operations](../../operations/README.md) |
