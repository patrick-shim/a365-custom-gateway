# Provisioning implementation guide

This is the shared source of truth for Claude, Codex, Copilot, humans, and delegated
agents working on Entra Agent ID and Agent 365 provisioning.

Read `AGENTS.md`, `CLAUDE.md`, `docs/implementation-status.md`, this guide, and the
latest `docs/operations/development-deployment-status.md` checkpoint before any
Azure, SQL, Entra, Service Bus, Graph, deployment, or live registration action.

## Authority and truth boundary

Use this order when sources disagree:

1. Implemented code/tests, deployed Gateway contract, and authorized live evidence.
2. Current official Microsoft documentation.
3. Current shared status and agent guides.
4. Architecture, API, decision, and runbook documents.
5. `docs/spec/full-spec.txt` for product intent.

Never implement a Microsoft route, permission, role, auth mode, or payload from a
placeholder, old prototype, or CLI without current official validation. A passing
test, healthy Container App, operation row, or OTLP HTTP 200 is not independent
proof that the external resource/effect exists.

## Current checkpoint

Continuous development is proven for both blueprint modes. Create-new registration
`fb35a5ce-8df5-48c2-86e9-9411d17df070` completed safely through retry operation
`6395ab47-e6c8-4584-8867-36c5c09f9475`; reusable-blueprint registration
`ff685604-999c-4584-9cec-87ec21f870ee` completed operation
`099248a5-e1a3-4c50-a456-d0a04a6f1933`. Their full blueprint/child/Registry maps
are in `../implementation-status.md`. Both are Available in Microsoft 365 Admin
Center. Current queues are v3 `0/0/9`, retained v2 `0/0/3`, and historical
`0/0/2`; all DLQs remain evidence-only.

Blueprint-scoped Purview Enforce is live. Benign content returns `AuditLogged`, a
synthetic credit-card `uploadText` returns `Blocked`, and `downloadText` is processed
offline. The exact release gate is 1,119/1,119; authoritative counts and deployment
digests belong in `../implementation-status.md`.

Current unreleased source also provisions optional Azure AI Content Safety Prompt
Shields independently of Agent ID provisioning. Bicep creates one regional
Content Safety account with local authentication disabled and grants the Gateway
API managed identity the built-in Cognitive Services User role. It injects only the
resource endpoint; runtime tokens use
`https://cognitiveservices.azure.com/.default`. The feature adds no workflow-v3
stage, Entra blueprint mutation, FIC, child Agent ID role, or Registry action. It is
source-only until a separately authorized migration/deployment/readback and bounded
data-plane canary are recorded.

### Historical superseded checkpoint

At that historical checkpoint, local workflow-v3 source passed a zero-warning/error
build; 1,086/1,086 tests (unit 384, Admin UI 149, end-to-end 103,
security 111, runtime 142, integration 92, architecture 105); and PowerShell parsing
19/19. Every test project was run directly with `--no-restore`. The preceding
architecture-test-project format verification passes. The preceding static/
deployment checkpoint also passed `dotnet format`, Bicep 19/19 templates and
5/5 parameters, OpenAPI YAML parsing, and diff checks.

The workflow-v3 development canary is now manual and non-replayable. External ID
`agent-v3demo-20260827030009-3c870882`, Gateway registration
`583777f0-c601-4c09-9e28-27dab51ae375`, and operation
`5c4ba41d-24e5-473c-9126-f89f37f7bb18` resolve to child Agent ID
`0a2e20d5-6299-4e02-a94e-0c6232a55113` and persisted blueprint ID
`29fa5cc5-c42b-4bdc-8f99-d85a5b91ad01`. Safe key ID is
`47b13283-5be7-4fc2-88d2-7fef34642214`; never expose or attempt to recover the clear
value. Worker stages 1--5 completed. One signed-in Administrator action crossed the
Registry create boundary exactly once and returned an ambiguous outcome before a
durable Registry ID existed. The operation is `RequiresManualIntervention` at 71%
with `PROVISIONING_AMBIGUOUS_RESULT`; no final-stage enqueue, data-plane proof, or
telemetry proof exists.

Live completion exposed and fixed three pre-POST defects: a controller nullable-GUID
bug, production scope-claim mapping, and GUID-only parsing of Graph string resource
IDs. No Registry POST intent or request was issued. The corrected API digest is
`sha256:217b466a8820fd7479ceb0e75d88b0011002760fc0d144111bec8f3a7becfb74`.
Clean interactive reauthentication later made the exact retained-FIC GET succeed
without new delegated consent. The one exact-operation completion window was
consumed by the ambiguous action above.

Final recovery left API `ca-gateway-api-dev--canaryclosed-20260828075643` closed and
worker `ca-gateway-worker-dev-vnet--inert-20260828080507` inert on digest
`sha256:d3630499703da99e4b25a1150c2a646111eea7cc6629da7f5b4f35dc8928ecda`.
The v3 queue is 0/0/0, retained v2 is 0/0/3, historical v1 is 0/0/2, and SQL
finalization is unapplied. Final evidence
`live-state-20260828-v3-post-completion.json` proves outbox 0, v3 active 1/awaiting
0, v2 active 3, and legacy active 2.

The three v2 failures remain immutable evidence:

1. incompatible `pat-blueprint`, GET-only failure at Resolve Blueprint, no mutation;
2. compatible `simple-echo-agent Blueprint`, one FIC POST returned 201, immediate
   stale read failed closed, later read-only reconciliation proved one correct
   reusable FIC and no child/role/Registry/telemetry mapping; and
3. registration `b23cb073-912e-4efa-8a01-88a46b2af5fb`, operation
   `8ece1c62-df73-4185-8f73-7b27db080414`, child
   `8e4859bd-477c-4133-adb1-9030ec13bf5c`, which reused the FIC, created/verified the
   child and OtelWrite, then received HTTP 500 from its one app-only Registry POST
   without a durable ID. It remains manual at 71%.

Exact portal searches found no visible third-canary record but are not API proof.
Never retry, attach, delete, second-POST, or access/dispose of any retained item.
That historical outcome remains unresolved and non-replayable, but it is not a
workflow-v3 input.

That historical one-shot action remains consumed and must never be retried. It no
longer defines the current development admission model: development now runs the
explicit continuous mode and has distinct Active registrations. Production,
destructive cleanup, retained resource/message mutation, credential disclosure,
historical replay, and SQL finalization remain separate reviewed workstreams.

## N:N contract

```text
Gateway key -> AgentRegistration -> reusable blueprint + distinct child Agent ID
                                            |
                                            v
                                         Agent 365
```

- Every registration owns its generated external ID, Gateway keys, child Agent ID,
  feature settings, and selected blueprint mapping.
- A blueprint may be reused by many registrations. Its Gateway-worker FIC is reused
  at blueprint scope; it is not created per registration.
- The clear Gateway key is returned once. SQL stores salted verifier/lifecycle data
  only. The key resolves the caller registration before body `externalAgentId` is
  cross-checked.
- External clients do not submit managed-identity IDs or Entra tokens for ordinary
  ingress.
- Agent 365 export uses the authenticated registration's child/blueprint pair and
  `fmi_path=<child-agent-id>`.
- Activity, batch, and interaction idempotency is registration + endpoint + key +
  canonical hash scoped. One-time secret responses are never cached.

Do not copy the N:1 prototype's singleton Agent ID/global-key model.

## Validated Microsoft model

| Capability | Mechanism | Required identity/permission | Workflow-v3 decision |
|---|---|---|---|
| List/select blueprint | `GET /v1.0/applications/microsoft.graph.agentIdentityBlueprint` | API catalog and worker: `AgentIdentityBlueprint.Read.All` application role | Return typed object ID, app/client ID, display name, and safe compatibility. |
| Create blueprint | `POST /v1.0/applications/microsoft.graph.agentIdentityBlueprint` | Worker: `AgentIdentityBlueprint.Create` | Sponsor required; ordinary Entra apps are not blueprints. |
| Ensure blueprint principal | `POST /v1.0/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal` | Worker: `AgentIdentityBlueprintPrincipal.Create` | Persist and verify the service-principal object ID. |
| Configure Gateway FIC | `POST /v1.0/applications/{blueprint-object-id}/federatedIdentityCredentials` | Worker: `AgentIdentityBlueprint.AddRemoveCreds.All` | One deterministic FIC per worker principal/blueprint; sole audience `api://AzureADTokenExchange`. |
| Create child Agent ID | `POST /v1.0/servicePrincipals/microsoft.graph.agentIdentity` | Worker: `AgentIdentity.Create.All`; read with `AgentIdentity.Read.All` | Use blueprint `appId` as `agentIdentityBlueprintId` and require sponsor. |
| Assign Agent 365 role | `POST /v1.0/servicePrincipals/{child-id}/appRoleAssignments` | Worker: `AppRoleAssignment.ReadWrite.All`, `Application.Read.All` | Assign only `Agent365.Observability.OtelWrite` on Agent 365 resource app `9b975845-388f-4429-889e-eab1ef63949c`. |
| Create Registry record | `POST /beta/copilot/agentRegistrations` | Signed-in Administrator through API OBO; delegated `AgentRegistration.ReadWrite.All` | API-owned, one POST with persisted planned `id` and reviewed `managedByAppId`; persist the safe returned/fallback ID. Beta, Global-only, unsupported for production. |
| Read Registry record | `GET /beta/copilot/agentRegistrations/{id}` | Same OBO user; delegated `AgentRegistration.Read.All` | Read-only reconciliation when available; it is not the immediate HTTP 201 acceptance gate. |
| Agent 365 token | worker assertion -> blueprint token with `fmi_path=<child-id>` -> child token | Child gets `Agent365.Observability.OtelWrite` | Validate audience, child `appid`/`azp`, and role. |

Official references:

- [list blueprints](https://learn.microsoft.com/en-us/graph/api/agentidentityblueprint-list?view=graph-rest-1.0)
- [create blueprint](https://learn.microsoft.com/en-us/graph/api/agentidentityblueprint-post?view=graph-rest-1.0)
- [create blueprint principal](https://learn.microsoft.com/en-us/graph/api/agentidentityblueprintprincipal-post?view=graph-rest-1.0)
- [create FIC](https://learn.microsoft.com/en-us/graph/api/federatedidentitycredential-post?view=graph-rest-1.0)
- [get FIC](https://learn.microsoft.com/en-us/graph/api/federatedidentitycredential-get?view=graph-rest-1.0)
- [FIC propagation](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-considerations)
- [create Agent Identity](https://learn.microsoft.com/en-us/graph/api/agentidentity-post?view=graph-rest-1.0)
- [Registry create](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/api/admin-settings/agent-registration/agentregistration-create)
- [Registry get](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/api/admin-settings/agent-registration/agentregistration-get)
- [Registry resource](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/api/admin-settings/agent-registration/resources/agentregistration)
- [OAuth 2.0 OBO](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-on-behalf-of-flow)
- [certificateless Microsoft.Identity.Web](https://learn.microsoft.com/en-us/entra/msidweb/authentication/certificateless)
- [autonomous Agent ID token flow](https://learn.microsoft.com/en-us/entra/agent-id/autonomous-agent-authentication-authorization-flow)

### Identifier semantics

- Blueprint Graph `id` is its application object ID; `appId` is its application/
  client ID. They are route-specific fields but may contain the same GUID. Persist
  both named properties and never infer inequality or substitute another ID.
- Microsoft currently documents the child Agent Identity object/client IDs as the
  same GUID. Contracts retain separate names for clarity and verify the returned
  model.
- Gateway API app/client ID, API managed-identity principal ID, worker principal,
  blueprint principal, Registry ID, Gateway registration, external ID, and
  credential ID are distinct concepts.

### Exact worker and API permissions

The v3 worker needs exactly eight Microsoft Graph application roles:

1. `Application.Read.All`
2. `AppRoleAssignment.ReadWrite.All`
3. `AgentIdentityBlueprint.Create`
4. `AgentIdentityBlueprint.AddRemoveCreds.All`
5. `AgentIdentityBlueprintPrincipal.Create`
6. `AgentIdentityBlueprint.Read.All`
7. `AgentIdentity.Create.All`
8. `AgentIdentity.Read.All`

The worker must not retain `AgentRegistration.Read.All` or
`AgentRegistration.ReadWrite.All`. The Gateway API managed identity separately
needs `AgentIdentityBlueprint.Read.All` for the catalog. The Gateway API app needs
exactly the two delegated Registry scopes with tenant-wide admin consent. Signed-in
Global Administrator status alone supplies neither backend application roles nor
delegated consent.

### API OBO confidential credential

The Admin UI continues to request only the Gateway API `access_as_user` scope. The
API then uses Microsoft.Identity.Web OBO for the Graph Registry scopes. The Gateway
API app's confidential credential is a federated managed-identity assertion:

```text
issuer:   https://login.microsoftonline.com/<tenant-id>/v2.0
subject:  <API Container App managed-identity principal object ID>
audience: api://AzureADTokenExchange   (exactly one)
```

Create/reuse exactly one matching FIC and fail on duplicates or conflicts. Do not
store a client secret. Do not grant the Azure CLI delegated consent as a workaround.
Consent belongs on the Gateway API app and must be verified by exact grant readback.

## Canonical workflow v3

### Worker prefix: stages 1--5

Each message names the expected job/step index. The worker takes a dedicated SQL
connection and a session-owned exclusive `sp_getapplock` keyed by job ID across the
stage attempt. It verifies the current v3 shape and prior safe state, invokes one
provider stage, persists the result, and queues the next index.

After `AssignAgent365Access` completes, the worker:

- records five completed rows and 71%;
- sets job `AwaitingAdministratorAction`;
- sets agent `AwaitingAdminApproval`;
- leaves `RegisterAgent` and final verification pending;
- exposes `AGENT365_REGISTRY_ACTION_REQUIRED`; and
- publishes no continuation.

A stale or forged queued Register message is completed as a no-op. It never reaches
the provider's historical Registry helper.

### User-only Registry action: stage 6

`GET /api/v1/operations/{id}` exposes
`requiredAction=CompleteAgent365Registration` only for the exact current shape. The
UI shows the action only to Administrators; other roles see an Administrator
handoff. The API endpoint requires:

- authenticated user;
- `Gateway.Administrator`;
- valid nonempty Entra `oid`;
- delegated `scp` containing `access_as_user`;
- a deployment mode that permits delegated completion; and
- when exact binding is enabled, an unexpired gate bound to this operation ID.

In staging/production the two exact-bound windows are independent: registration is
first bound to one generated external ID and completion is later bound to the
resulting operation. In explicitly configured continuous development, both exact
bindings are false and the signed-in Administrator UI performs the action once
automatically. Continuous mode never weakens the endpoint's user, role, scope, OBO,
SQL-lock, or one-POST checks.

The handler takes the same per-job lock and rejects all v1/v2 jobs before token
acquisition or mutation. It validates a contiguous five-step prefix and constructs:

- display name/description from the Gateway registration;
- `ownerIds` from the accountable owner;
- Gateway generated external ID as `sourceAgentId`;
- configured originating store;
- verified child Agent Identity object ID;
- verified blueprint client ID;
- a creator-bound planned Registry ID as `id`;
- the reviewed direct-preview provider application as `managedByAppId`;
- signed-in Administrator `oid` as `createdBy`; and
- source create/modified timestamps.

It pre-acquires the OBO token before persisting intent so consent or Conditional
Access can surface without a Registry attempt. It then persists the creator-bound
planned ID, issues at most one POST, requires 201, and persists the safe returned ID
immediately with cancellation suppressed at that durability boundary. If a
successful response omits an ID, the planned ID is the bounded fallback. This
matches the working CLI-compatible acceptance semantics; the preview collection's
immediate exact GET is not a creation gate.

Result handling is strict:

- token/consent/authorization failure before POST -> return to Administrator wait;
- nonambiguous request rejection before mutation -> return safely or fail with the
  controlled error; no POST retry inside the same action;
- transport/timeout/5xx/ambiguous outcome -> exact planned-ID GET only, never a
  second POST; transient reads remain creator-bound and GET-only, while mismatch or
  nonrecoverable ambiguity becomes manual;
- accepted 201 plus durable returned ID -> persist `DelegatedAdministrator`, creator
  ID, and accepted timestamp; complete Register at 85%, audit, and atomically enqueue
  only expected index 6.

Tokens, assertions, authorization headers, and raw dependency bodies are never
persisted or logged.

### Worker final verification: stage 7

The worker accepts only a persisted Registry GUID with provider
`DirectRegistryPreview`, auth mode `DelegatedAdministrator`, valid creator GUID, and
Registry acceptance timestamp. It makes no Registry request. It independently
reads/verifies blueprint, blueprint principal, child Agent ID, OtelWrite assignment,
the exact worker FIC (including sole audience), and the child Agent 365 token. It
then persists the connection-verification timestamp and makes the registration
`Active` at 100%.

### Retry safety

Retry is available only when every provisioning job is workflow v3, no job/step is
active or awaiting action, no ambiguous Registry boundary exists, and the newest
terminal failure has a contiguous, deserializable, safe-evidence, monotonic prefix.
Reviewed manual configuration failures are eligible only when their persisted
prefix makes the next action unambiguous.

- Failure before Register: clone completed prefix and resume the first incomplete
  worker stage; if Register is next, create an Administrator-wait job and no outbox.
- Failure after accepted Registry completion: clone all six completed rows and enqueue
  only final verification.
- A running Registry attempt may repeat only exact planned-ID GET under the same
  creator; any ambiguous terminal history and any legacy v1/v2 job never retries.

`Agent365ProvisioningState.PlannedAgent365RegistrationId` is retained only for old
serialized state/source compatibility. The current API attempt state separately
persists its planned Registry ID as the one-POST/exact-GET recovery invariant.

## Queue ownership

- workflow-v3 API publisher/worker: `gateway-provisioning-v3`;
- New-blueprint Purview protection profiles do not add or reorder persisted
  workflow-v3 steps. After `ResolveBlueprint` returns the blueprint application ID,
  the worker idempotently creates or extends the selected Gateway-managed
  collection/DLP policy pair, preserves every existing Application location, and
  requires exact readback before completing that stage. A failure occurs before
  child Agent ID creation. Automation uses the dedicated certificate-authenticated
  Security & Compliance application; it never uses a Gateway key, child identity,
  blueprint identity, or signed-in administrator token.
- retained workflow-v2 artifacts/worker: `gateway-provisioning-v2`;
- historical workflow-v1 worker: `gateway-provisioning`.

The API is the v3 outbox publisher. The v3 worker relay stays off. Grant the API
queue-scoped Sender and the v3 worker queue-scoped Receiver only; broader namespace
or opposite-direction roles fail activation. Preserve retained DLQs without peek,
receive, settle, replay, purge, or forwarding.

## Rollout from this checkpoint

Follow the latest deployment checkpoint; do not infer completion from this guide.

1. Preserve both Active registrations, their mappings, safe credential boundaries,
   and every retained v1/v2/v3 failure item.
2. Preserve Admin Center landing and blueprint-scoped DLP proof.
3. Run staging multi-replica/failover/recovery tests next; do not use historical
   failures as inputs.
4. Treat SQL finalization, resource deletion, retained-message disposition, and
   production rollout as separately reviewed actions.
5. Before enabling Prompt Shields for a live registration, apply
   `20260829_prompt_protection.sql`, deploy the API/UI/source image and Content
   Safety resource, verify the exact API managed-identity role assignment and
   provider readiness read-only, then run allow/block/receipt-consumption tests.

## Completion and production gates

At minimum, automated tests cover exact stage order, worker pause/no Registry call,
user-only policy, consent/claims challenge before mutation, one-POST durability,
accepted-create recovery, atomic final enqueue, final
verification without Registry HTTP, retry prefix cloning, legacy rejection,
session-owned job locking, child token validation, FIC audience, salted keys,
scoped-idempotency races, SQL limiting, and secret exclusion. Tests use local fakes
and never mutate a tenant.

The core development demo is complete for new and reused blueprints: Entra readbacks
and Registry acceptance are durable, key binding and ingress are proven, Agent 365
transport is accepted, Admin Center landing is confirmed, and blueprint-scoped
prompt DLP blocks synthetic sensitive input. Response-side inline enforcement is a
future product boundary because `downloadText` is offline.

Production remains unclaimed until a supported non-beta Registry provider exists;
multi-replica/failover/staging stress passes; deletion/reconciliation has a supported
operational answer; and production security, privilege, HA, capacity, backup,
retention, and incident reviews pass.

## File ownership

| Role | Primary files |
|---|---|
| Provisioning builder | `src/Gateway.Agent365`, `src/Gateway.Provisioning.Worker` |
| API builder | delegated Registry endpoint/OBO under `src/Gateway.Api`, `Gateway.Application`, shared contracts |
| Admin UI builder | operation required-action UX and typed client |
| Test writer | provisioning-focused files under `tests/` |
| Deployer | provisioning-related `infrastructure/`, `operations/`, workflows, and assigned runbooks |
| Documentation validator | Microsoft validation matrix and citations |
| Security reviewer | read-only identity, permission, redaction, recovery review |

Coordinate shared contracts and never edit overlapping files concurrently.

`.secrets` may be consumed only by the authorized non-echoing deployment path.
Never inspect it for documentation work, print it, copy it, alter it, transmit it,
or commit it.
