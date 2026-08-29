# A365 Gateway implementation status

This is the living cross-agent handoff. Read it with `AGENTS.md`, `CLAUDE.md`, the
relevant guide under `docs/agent-guides`, and the latest live evidence in
[`operations/development-deployment-status.md`](operations/development-deployment-status.md).

Last reconciled with the workflow-v3 working tree, continuous development
deployment, Microsoft 365 Admin Center landing, blueprint-scoped Purview DLP proof,
the clean-subscription bootstrap source checkpoint, the unreleased Purview
protection-profile source feature, and the unreleased pre-model prompt-protection
source feature:
**2026-08-29**.

## Unreleased source checkpoint: pre-model prompt protection

Current source implements an explicit pre-model contract without turning the
Gateway into a model proxy. A registration may enable Azure AI Content Safety
Prompt Shields, Purview, both, or neither. The registration-bound client calls
`POST /api/v1/prompts:evaluate` with a UUIDv4 `Idempotency-Key` before model
invocation. Enabled checks run concurrently and fail closed. A block returns HTTP
403 RFC 9457 details with one safe code—`PROMPT_BLOCKED_BY_PROMPT_SHIELD`,
`PROMPT_BLOCKED_BY_DLP`, or `PROMPT_BLOCKED_BY_MULTIPLE_CONTROLS`—and no receipt.
An untrusted provider outcome returns 503 and no allow.

An allow returns a short-lived, single-use receipt. SQL stores decision metadata,
expiry/consumption state, and a random-salt SHA-256 prompt verifier; it never stores
the raw evaluation prompt. The receipt binds the registration, interaction ID,
tenant user, content type, and exact prompt. A protected
`POST /api/v1/ai-interactions` validates and consumes it only after acquiring the
scoped idempotency lease and checking for a replay. This preserves same-request
replay; an atomic transaction-bound compare-and-set prevents a second request with
a different idempotency key from consuming the same receipt. The handler rejects a
missing, expired, consumed, cross-registration,
cross-user, cross-interaction, or prompt-mismatched receipt before Blob/Purview/
outbox work.

`Gateway.ContentSafety` uses the API managed identity for
`https://cognitiveservices.azure.com/.default` and calls
`shieldPrompt` API `2024-09-01`; no account-key fallback exists. Bicep/bootstrap can
create the Content Safety account with local authentication disabled and grant the
API identity only Cognitive Services User. Migration
`20260829_prompt_protection.sql` adds per-registration/default flags and
`PromptEvaluationRecords`. Admin registration, detail, and settings pages expose
availability-aware controls. `ExternalAgent.Sample` now evaluates its configurable
`--message`, prints only safe provider/decision evidence, exits on block, and sends
the allowed receipt with the completed interaction.

The complete local Release gate is **1,119/1,119**: unit 409, Admin UI 151,
end-to-end 106, security 111, observability/runtime 144, integration 92, and
architecture 106. Release build is zero-warning/error; format verification passes;
PowerShell parses 26/26; Bicep compiles 20/20 templates and validates 5/5 parameter
files; OpenAPI YAML and bootstrap JSON parse. This is source evidence only. No SQL
migration, Content Safety resource/role, image, Admin UI revision, live prompt
evaluation, or Azure deployment changed in this checkpoint.

## Unreleased source checkpoint: Purview protection profiles

The current working tree adds an Admin UI experience for a Purview-enabled **new**
blueprint: the administrator selects a verified reusable protection profile or
creates a new reviewed profile while registering the agent. A profile is a durable,
non-secret Gateway record pairing one Know Your Data collection policy, one DLP
policy, and one DLP rule. It scopes the reusable blueprint application ID—not each
child Agent ID—so later blueprints can reuse the same policy pair without policy
sprawl.

This feature preserves workflow v3 and its seven persisted step values. During
`ResolveBlueprint`, after Graph returns the exact blueprint application ID, the
worker uses certificate-based app-only `Connect-IPPSSession` to create or safely
extend the profile. Existing `Locations` are read, preserved, and written back with
the new `Application` location. Both the collection policy and DLP policy must read
back the exact blueprint ID before `ResolveBlueprint` completes; otherwise the
workflow fails closed before a child Agent ID is created. `AuditOnly` maps to DLP
`TestWithoutNotifications`; `Enforce` maps to `Enable`. The clear certificate and
password are never persisted or logged; the base64 PKCS#12 is fetched from a Key
Vault secret and materialized only in a short-lived worker-private directory.

The source checkpoint includes the typed request/catalog contracts,
`GET /api/v1/purview-policy-profiles`, SQL migration
`20260829_purview_policy_profiles.sql`, worker automation, Container Apps settings,
clean-subscription bootstrap wiring with least-privilege worker Key Vault access,
Admin UI, OpenAPI, and focused tests. It is **not deployed evidence**. Before any
live rollout: review the Security & Compliance app role/RBAC, store the automation
certificate in the designated Key Vault, run the additive migration, build the new
worker image (which pins ExchangeOnlineManagement 3.10.1), deploy with policy
provisioning disabled, complete read-only preflight, then authorize one bounded
development canary separately.

## Product outcome

The Gateway is an N:N broker:

```text
external registration + one-time Gateway key
                    |
                    v
         Gateway registration and policy
                    |
          selected reusable blueprint
                    |
          distinct child Entra Agent ID
                    |
                 Agent 365
```

One Gateway accepts many external registrations. A reusable Agent Identity
blueprint can serve many registrations, but every registration owns its generated
`externalAgentId`, Gateway-key lifecycle, child Agent ID, feature settings, route,
and audit boundary. Ordinary external clients do not submit a managed-identity
object ID and do not need an Entra token. The Gateway key resolves the caller's
registration before the request body's `externalAgentId` is cross-checked.

The clear Gateway key is returned once. SQL stores only its key ID, random salt,
salted verifier, registration binding, and lifecycle metadata. A lost clear value
cannot be revealed; issue, deploy, verify, and then revoke a replacement.

## Current source contract: workflow v3

Workflow v3 retains seven ordered, persisted stages but splits their execution
across two trusted identities:

1. **Resolve Blueprint** (`ResolveBlueprint`) — worker
2. **Ensure Blueprint Principal** (`EnsureBlueprintPrincipal`) — worker
3. **Configure Gateway Federation** (`ConfigureGatewayFederation`) — worker
4. **Create Agent Identity** (`CreateAgentIdentity`) — worker
5. **Assign Agent 365 Access** (`AssignAgent365Access`) — worker
6. **Register in the Agent 365 preview Registry** (`RegisterAgent`) — signed-in
   Gateway Administrator through the API's delegated OBO flow
7. **Verify Agent 365 Connection** (`VerifyAgent365Connection`) — worker

The worker executes stages 1--5 one persisted stage per Service Bus message. After
stage 5 it sets the job to `AwaitingAdministratorAction`, the agent to
`AwaitingAdminApproval`, leaves `RegisterAgent` pending, reports 71%, and enqueues no
continuation. A stale queued `RegisterAgent` message is a no-op and can never cause
a worker-side Registry mutation.

`GET /api/v1/operations/{operationId}` then exposes
`requiredAction=CompleteAgent365Registration`. In continuous development the Admin
UI invokes the Gateway Administrator-only action automatically once and resumes
polling; exact-bound deployments render it as an explicit action. Both paths call:

```text
POST /api/v1/operations/{operationId}:complete-agent365-registration
```

The endpoint requires an authenticated user token with `access_as_user`, a valid
Entra `oid`, and the `Gateway.Administrator` application role. App-only callers,
operators, auditors, support readers, and malformed user tokens are rejected. The
API remains the authorization boundary.

The gates support two explicit modes. Staging and production default closed and use
independent, exact-bound, expiring windows: one generated external ID for
registration, then one resulting operation ID for delegated completion. Development
may set continuous admission/action flags while leaving exact binding false. The
continuous mode lets the authenticated Administrator UI automatically complete each
new operation, but it does not bypass user authentication, role/scopes, OBO,
session-owned SQL locking, or the one-POST Registry boundary. The exposed
`authorizedRegistrationExternalAgentId` exists only in exact-bound mode and is
routing/admission metadata, not a credential.

### Delegated Registry boundary

The API exchanges the current administrator's Gateway API access token for a
Microsoft Graph token through OAuth 2.0 on-behalf-of. The Gateway API app requires
admin-consented delegated scopes, and only these scopes:

- `AgentRegistration.ReadWrite.All`
- `AgentRegistration.Read.All`

The API confidential-client credential is a managed-identity signed assertion, not
a secret. The Gateway API app needs one federated identity credential whose issuer
is the tenant v2 issuer, subject is the API Container App managed-identity principal
object ID, and sole audience is `api://AzureADTokenExchange`. Tokens and assertions
remain process-local and must never be logged, persisted, queued, or documented.

The completion handler takes the same session-owned per-job SQL `sp_getapplock` as
the worker and accepts only the exact workflow-v3 shape with a contiguous verified
five-stage prefix. It pre-acquires the delegated token before recording Registry
POST intent. It then follows this durable boundary:

1. persist a creator-bound attempt marker containing a planned Registry ID;
2. issue at most one `POST /beta/copilot/agentRegistrations`, including that `id`
   and the reviewed preview-provider `managedByAppId`;
3. require HTTP 201 and immediately persist the safe Registry `id` returned by the
   service, using the planned ID only when the successful response omits one;
4. record that accepted create boundary without requiring an immediate exact GET
   from the eventually visible preview collection; and
5. atomically complete `RegisterAgent`, record delegated acceptance evidence,
   set progress to 85%, and enqueue only stage 7.

The create payload uses the Gateway external ID as `sourceAgentId`, the stored owner
in `ownerIds`, the signed-in administrator `oid` as `createdBy`, and the verified
child Agent Identity and blueprint client IDs. It also carries the persisted planned
`id` and the direct-preview provider's reviewed `managedByAppId`, matching the
working CLI-compatible boundary while retaining Gateway-owned source identity.

If delegated consent or token acquisition fails before the POST marker, the job
returns to the administrator-action state without a create. If the POST outcome is
unknown, only exact GET of the persisted planned ID is permitted; the POST is never
repeated. A transient read leaves the creator-bound action available for GET-only
repetition, while mismatch or nonrecoverable ambiguity becomes manual. A durable
HTTP 201 response and safe ID are accepted without immediate exact GET.

After delegated acceptance, the worker runs stage 7. It does not call the Registry.
It trusts only the persisted delegated Registry evidence, then independently
reverifies the blueprint, blueprint principal, Gateway FIC, child Agent ID,
`Agent365.Observability.OtelWrite` assignment, and child Agent 365 token. Only then
does the job become `Completed` and the registration `Active`.

### Safe retry boundary

Administrative retry remains fail-closed. It rejects legacy/non-v3 history,
active/running/awaiting jobs, ambiguous Registry outcomes, unsafe Registry attempt
state, and noncontiguous or nonmonotonic persisted evidence. A reviewed v3 manual
configuration failure may be retried only when its durable prefix and Registry
acceptance make the next action unambiguous. A safe pre-Registry failure clones only
its completed prefix. A post-Registry final-stage failure clones all six completed
steps and enqueues only stage 7; it never recreates the Registry record. A retry
whose first incomplete step is `RegisterAgent` waits for administrator action and
enqueues nothing.

`Agent365ProvisioningState.PlannedAgent365RegistrationId` and the old application-
authenticated Registry helpers remain only as historical serialized-state/source
compatibility. Current workflow-v3 API attempts instead persist
`Agent365RegistryAttemptState.PlannedAgent365RegistrationId` before the one
delegated POST. The worker cannot invoke either Registry path.

## Other implemented boundaries

| Area | Current source truth | Truth boundary |
|---|---|---|
| Admin UI | Signed-in owner and generated external ID are prefilled. Existing blueprints come from the typed catalog. Agent 365 defaults on; Azure Monitor mirror defaults off; Purview is independent. The operation page presents the required delegated Registry action only to Administrators. | UI state and a completed Gateway row do not independently prove a Microsoft resource. |
| Gateway ingress | Registration-scoped Bearer keys, issue/list/revoke, readiness, caller-registration-first routing, constant-time verification, and body-ID mismatch rejection are implemented. | Readiness also requires the registration to be in an allowed state. |
| Data integrity | Activity, batch, and interaction idempotency is registration + endpoint + key scoped with canonical request hashing and a SQL transaction-owned lock. SQL-backed global, registration, and credential rate buckets fail closed. | Real multi-replica/failover stress remains a production gate. |
| Queue isolation | Current source publishes/consumes workflow v3 on `gateway-provisioning-v3`. Retained workflow v2 remains on `gateway-provisioning-v2`; historical v1 remains on `gateway-provisioning`. | Never attach a v3 receiver to either retained queue or dispose of their messages. |
| Microsoft provisioning | Typed Graph v1.0 blueprint, principal, FIC, child Agent Identity, and app-role operations are worker-owned. Registry create/read is API-owned delegated Graph beta. | Unknown Microsoft mutation outcomes fail closed. Deletion/reconciliation remain unsupported. |
| Agent 365 | Each child receives `Agent365.Observability.OtelWrite`. One worker FIC is reused per blueprint and `fmi_path=<child-agent-id>` selects the child token. | OTLP HTTP 200 is transport acceptance only; downstream landing requires matching Defender evidence. |
| Purview | The API-managed-identity adapter uses official Graph v1.0 user-scope, process-content, and content-activity contracts and fails closed. The selected reusable blueprint client ID is the protected application location; child plus blueprint IDs are Enforce `aiAgentInfo`. | Blueprint-scoped `uploadText` inline DLP is live-proven. `downloadText` is submitted offline, so the completed-pair route is not a pre-model response gate. |

### Current worker Graph application-role allowlist

Workflow v3 removes Registry application permissions from the worker. The exact
worker allowlist is eight roles:

1. `Application.Read.All`
2. `AppRoleAssignment.ReadWrite.All`
3. `AgentIdentityBlueprint.Create`
4. `AgentIdentityBlueprint.AddRemoveCreds.All`
5. `AgentIdentityBlueprintPrincipal.Create`
6. `AgentIdentityBlueprint.Read.All`
7. `AgentIdentity.Create.All`
8. `AgentIdentity.Read.All`

The API managed identity separately needs `AgentIdentityBlueprint.Read.All` for the
typed catalog. The two Registry permissions are delegated scopes on the Gateway API
app, not application roles on either managed identity. Signing in as Global
Administrator does not substitute for these backend assignments or admin consent.

`managerApplications` remains versioned tenant/provider configuration. For the
development tenant it was correlated from A365 CLI `1.1.214+90c444832f` and tenant
inventory to verified Microsoft 365 App Catalog Services. Never hard-code it as a
universal value.

Blueprint Graph `id` and `appId` remain separately named, route-specific fields and
may contain the same GUID. The current child Agent Identity object/client fields are
also documented as the same GUID while remaining separately named. Gateway
registration, credential, external, worker principal, API app, blueprint,
blueprint-principal, child, and Registry identifiers are not interchangeable.

## Local verification checkpoint

### Clean-subscription bootstrap source

`bootstrap/bootstrap.ps1` is now the supported first-deployment entry point. Its
`Plan`, `Apply`, `Resume`, and `Verify` modes persist safe step evidence under the
ignored `.bootstrap/` directory and reject concurrent runs. The bootstrap creates
the resource group and VNet-integrated Container Apps foundation, composes the
reviewed workload Bicep, creates/adopts the API and Admin UI Entra applications,
creates a typed seed blueprint through the Agent 365 CLI, configures the exact
workflow-v3 roles/delegated consent/OBO FIC, builds digest-pinned images in ACR,
adds SQL/Key Vault private endpoints, initializes an empty current-model database,
creates runtime database principals, optionally authors blueprint-scoped Purview
policies and provisions managed-identity Prompt Shields, deploys the Admin UI,
closes public dependency access, and performs the
read-only provisioning preflight plus health checks.

Every Apply/Resume rechecks prerequisites and re-pins the exact Azure tenant and
subscription instead of trusting a prior-process login record; final verification
also always reruns. `-NonInteractive` refuses any missing Agent 365 blueprint or
Purview authoring step that would require an interactive login. When safe state
records a completed foundation but the exact resource group was subsequently
deleted, bootstrap clears only dependent safe state and rebuilds through the same
idempotent/adoption paths.

The bootstrap has no destroy path and does not read `.secrets`. Generated SQL/app
credentials remain process-local or are transferred directly to Key Vault; state
contains only safe IDs, URIs, digests, timestamps, and verification results. The
direct Registry boundary is enabled only for `dev` with explicit preview opt-in;
staging/production remain closed because Microsoft's beta create API is unsupported
for production. Purview policy read-back is not a synthetic verdict, so adapter
activation is a separate explicit acknowledgement in configuration.

The repository layout now separates lifecycle concerns instead of overloading the
former `deploy/` directory. `bootstrap/` owns day-zero orchestration and resumable
state, `infrastructure/bicep` and `infrastructure/sql` own declarative assets,
`operations/` owns reviewed existing-environment deployment/preflight/canary
scripts, and `tools/` owns shared utilities. The old `deploy/` tree no longer
exists. Bootstrap modules, workflows, the database migrator, architecture tests,
runbooks, and paired Claude/Codex deployment instructions all reference the new
locations. This was a source-only relocation; no Azure or database state changed.

Source validation currently includes PowerShell parsing, all three new Bicep
templates, a zero-warning/error solution/DatabaseMigrator build, a successful
non-mutating `Plan`, the bootstrap architecture regression, and the full 1,119-test
gate. A complete `Apply` has
not yet been executed against a disposable clean subscription and is not live
deployment evidence. The next bootstrap-specific action is that disposable
development execution followed by a real registration/data-plane/Purview canary;
record its safe evidence here before describing clean-subscription recovery as
live-proven.

The current broad workflow-v3 plus bootstrap gate has a zero-warning/zero-error
Release solution build and **1,119/1,119** passing tests:

- unit **409/409**;
- Admin UI **151/151**;
- end-to-end **106/106**;
- security **111/111**;
- observability/runtime **144/144**;
- integration **92/92**; and
- architecture **106/106**.

Every `tests/**/*.csproj` was run directly in Release with `--no-restore`; invoking
`dotnet test` against the solution alone runs no test projects. PowerShell parsing
passed 26/26, `dotnet format
--verify-no-changes` passed, all 20/20 Bicep templates compile without diagnostics,
and all 5/5 parameter files validate. Final diff checks pass;
line-ending notices are informational. Local success is not deployment evidence.

The first live `OpenDelegatedCompletion` invocation exposed a controller
`Nullable<Guid>.Value` defect before any user action. The controller is fixed and an
architecture regression test covers the operation-ID binding. Focused architecture
105/105 and PowerShell parser 19/19 pass after that fix; the complete 1,086/1,086
test-project gate and zero-warning/error Release build also pass.

The 2026-08-29 repository synchronization verified **54** Markdown files and all
**51** repository-local Markdown links with no broken targets. All **8** current
non-evidence JSON configuration files parse. The **15** Claude/Codex agent role
names match, and the three shared workstream skills are byte-identical across
`.claude/skills` and `.agents/skills`. The synchronization also removed the unused
159.83 MB bundled Python runtime, unused Bootstrap template assets, root build and
restore transcripts, rendered Container App YAML, and obsolete local launch
wrappers after reference checks found no consumer. Operational evidence and
incident records were preserved. No secret material was read or changed.

The same checkpoint hardened correlation-ID validation, request-scoped logging,
safe Problem Details, typed Admin UI API diagnostics, and deployment-script error
reporting so dependency bodies, tokens, keys, and exception messages do not cross
trust boundaries. The Admin UI now has keyboard-visible focus, a skip link, a
registration step navigator, actionable admission guidance, clearer search/result
states, and responsive navigation. These source/UI changes are locally test-proven
but are not represented as a new deployed Admin UI revision.

## Current deployed development checkpoint: continuous end-to-end demo

Development intentionally runs continuous registration, automatic signed-in
Administrator Registry completion, worker provisioning, and data-plane relay. At
least the two registrations below have independently captured end-to-end evidence.
A later user-run external-browser creation was reported successful, but its safe
identifier map and post-run SQL/queue snapshot were not independently captured in
this checkpoint; do not treat the two rows below as a complete current inventory.
The current healthy revisions are:

- API `ca-gateway-api-dev--purviewguard-20260828222324`, image digest
  `sha256:5275b3adcdb3e17f39e7b7466fc989bfeae04904f64f85226931be19c6e939b7`;
- worker `ca-gateway-worker-dev-vnet--rbacrefresh-202608282058`, digest
  `sha256:9dad873fe49b17c55677674688616c9770f8e3810c878702011632dda9dd7c9e`;
  and
- Admin UI `ca-gateway-admin-dev--continuous-202608282042`, digest
  `sha256:8a447f481294822141d550b9313c2bd3249dc1fea7430cefcc21f2a2ef1c876e`.

The create-new proof is:

- display/external ID `gateway-e2e-auto-20260828` /
  `agent-89a205c4340644debaf53248cfdfd8eb`;
- registration `fb35a5ce-8df5-48c2-86e9-9411d17df070`;
- blueprint `79a71594-6435-4c64-a7bf-5f472a475792`;
- child Agent ID `640f3b3a-1ff2-4ab5-b1a4-cfac59dd35de`;
- Registry ID `9451d70c-71b6-45eb-9db5-4be8f05c6d04`; and
- initial propagation failure `35d386c7-ef2f-4f9f-9dd5-cb4316f0afd4`, followed by
  safe completed retry `6395ab47-e6c8-4584-8867-36c5c09f9475`.

The first attempt failed only because Graph returned 404 while the new child
service principal propagated. The provider now retries the exact app-role assignment
POST only after an explicit 404; unknown outcomes are still never replayed.

The reusable-blueprint and DLP proof is:

- display/external ID `gateway-e2e-purview-control-20260828` /
  `agent-ef6f55ea1525406bb93997c2e8b771cd`;
- registration `ff685604-999c-4584-9cec-87ec21f870ee`;
- blueprint `29fa5cc5-c42b-4bdc-8f99-d85a5b91ad01`;
- child Agent ID `954fec63-53a7-4556-abaa-67acf11956c8`;
- Registry ID `b2bf22e4-3d2c-49b4-8ead-a003d2496dab`; and
- completed operation `099248a5-e1a3-4c50-a456-d0a04a6f1933`.

Microsoft 365 Admin Center shows both rows Available on `A365CustomGateway`. The
newest usage counters remain 0/0 immediately after submission, so they are treated
as delayed portal aggregation rather than transport proof; the older canary remains
the independent visual usage proof. Direct activity requests returned HTTP 202 and
the v3 queue drained.

Purview is enabled in Enforce for the reusable-blueprint registration. Policy
`A365 Tourist OBO Python DLP (OBS Gateway)` targets blueprint
`29fa5cc5-c42b-4bdc-8f99-d85a5b91ad01` with `EnforcementPlanes Application`.
Live correlation `de14f217-3380-42cb-9b9e-92df5a2e9ea7` returned
`Accepted/AuditLogged/Queued` for benign content. Correlation
`0c882b36-efe9-444e-bf86-d1b4415ea455` returned `Failed/Blocked/Pending` for the
authorized synthetic credit-card prompt; no observability message was queued for
the blocked interaction. Purview returns inline scope for `uploadText` and offline
scope for `downloadText`; the adapter now follows each mode instead of requiring
both activities to be inline.

Diagnostic credentials were overlap-rotated and verified before revocation. The
current safe key IDs are `ac74e01b-a7ec-4cb6-93d7-59c0cdfb7fbb` for the reusable-
blueprint registration and `b3abe5d0-7181-45aa-beb5-2dddba328f08` for the
create-new registration. No clear key is retained in evidence or documentation.

Queues are v3 `0/0/9`, retained v2 `0/0/3`, and historical `0/0/2`. The ninth v3
DLQ is the preserved first create-new propagation failure; no DLQ was accessed or
disposed. The latest exact SQL artifact,
`live-state-20260828-v3-success-final.json`, predates these two continuous canaries;
it remains valid historical evidence but its v3 job/outbox totals must not be called
current. SQL finalization remains unapplied.

## Historical superseded development checkpoint: first workflow-v3 canary

Workflow v3 is deployed in development subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216`. The single authorized delegated Registry
action was submitted once and returned an ambiguous create outcome before a durable
Registry ID was available. The operation is permanently non-replayable. The verified
recovered state is:

- API revision `ca-gateway-api-dev--canaryclosed-20260828075643`, ready on
  `sha256:217b466a8820fd7479ceb0e75d88b0011002760fc0d144111bec8f3a7becfb74`,
  with registration and delegated-action admission closed and no bindings/expiries;
- v3 worker revision `ca-gateway-worker-dev-vnet--inert-20260828080507`, ready on
  `sha256:d3630499703da99e4b25a1150c2a646111eea7cc6629da7f5b4f35dc8928ecda`,
  scale `0..1`, no command/argument override or migrator environment, and all
  processing, execution, Registry, preview, and relay gates false;
- `gateway-provisioning-v3` active 0, scheduled 0, DLQ 0;
- retained `gateway-provisioning-v2` active 0, scheduled 0, DLQ 3;
- historical `gateway-provisioning` active 0, scheduled 0, DLQ 2;
- exactly one active worker revision (the inert runtime revision); and
- SQL public network access disabled and scoped-idempotency finalization unapplied.

Pre-action read-only evidence
`artifacts/deployment-evidence/live-state-20260828-v3-completion-20260827223521.json`
proved outbox 0, v3 active 1/awaiting 1, v2 active 3, legacy active 2, and zero SQL
scripts. Post-action evidence
`artifacts/deployment-evidence/live-state-20260828-v3-post-completion.json`, verified
at `2026-08-27T23:03:32.2714306Z`, proves outbox 0, v3 active 1/awaiting 0, v2
active 3, legacy active 2, and zero scripts. The remaining active v3 count is the
non-completed manual-intervention job, not queued work or permission to replay it.

The preserved manual mapping is:

- external ID `agent-v3demo-20260827030009-3c870882`;
- Gateway registration `583777f0-c601-4c09-9e28-27dab51ae375`;
- operation `5c4ba41d-24e5-473c-9126-f89f37f7bb18`;
- child Agent ID `0a2e20d5-6299-4e02-a94e-0c6232a55113`;
- persisted blueprint ID `29fa5cc5-c42b-4bdc-8f99-d85a5b91ad01`; and
- safe Gateway-key ID `47b13283-5be7-4fc2-88d2-7fef34642214`.

Stages 1--5 completed. One signed-in Administrator action crossed the Registry
create boundary exactly once. It returned an ambiguous outcome before a durable
Registry ID could be recorded. The operation is `RequiresManualIntervention` at
71%; `RegisterAgent` is failed with `PROVISIONING_AMBIGUOUS_RESULT`, final
verification remains pending, and the registration is not `Active`. Correlation ID
`208097d1-e8aa-442f-bd50-e533ec16137f` is safe diagnostic metadata. There was no
final-stage enqueue, data-plane proof, Admin Center visibility proof, or telemetry
landing. The clear Gateway key must never be documented or recovered.

The first Arm attempt referenced nonexistent API digest
`sha256:de5866bf295db8fa7ba842f7e9b85217e744f4fe546ee149d0dd322ecb61b47b`
and failed at image pull before admission opened. Read-only recovery inspection
proved both API gates false, the older closed revision still serving health 200,
the worker inert, and all queue baselines intact. Guarded correction deployed the
reviewed API digest closed; corrected WhatIf and Arm passed.

Four earlier exact-bound registration windows for
`agent-v3demo-20260827030009-3c870882` opened and closed without submission,
registration, job, Gateway key, or Microsoft mutation. The first closed at
`2026-08-27T07:53:51.1109935Z`; fresh `0841` evidence then guarded windows whose
operator deadlines were `2026-08-27T09:04:42.7746751Z` and
`2026-08-27T09:17:51.6770322Z`. Fresh `0949` evidence guarded the fourth window,
whose operator deadline was `2026-08-27T10:11:26.1449657Z` and API-enforced crash
deadline was `2026-08-27T10:13:56.3860457Z`. The live form was prepared with display
name `axtstaa`, the exact reviewed external ID, `simple-echo-agent Blueprint`, Agent
365 on, Azure Monitor off, and Purview off, but the user did not click the submit
button. A later exact registration window succeeded and produced the in-progress
mapping above.

The first attempt to open delegated completion then hit the controller
`Nullable<Guid>.Value` bug before user action. Recovery returned API gates closed
and the worker inert. A stale pre-registration evidence re-Arm was correctly
rejected with no mutation; the narrow exact-image worker rearm used revision
`ca-gateway-worker-dev-vnet--resume-124250`. Two corrected completion windows opened
exact-bound to the operation and closed without user action, exact-operation API
logs, Registry request, or final enqueue. Their closed API revisions were
`ca-gateway-api-dev--delegatedclosed-20260827214632` and
`ca-gateway-api-dev--delegatedclosed-20260827220053`. Final Deactivate and Status
produced the closed/inert revisions above. The v3 queue remained `0/0/0`, and the
historical v2 ambiguity was not accessed or changed.

A later live administrator action first returned HTTP 403 before the controller or
Graph because the API policy recognized only the newer `scp` claim name. Microsoft
Identity Web also emits `http://schemas.microsoft.com/identity/claims/scope`; the
policy now accepts both documented forms while still requiring
`Gateway.Administrator`, a valid `oid`, and `access_as_user`. The next exact action
passed authorization but failed before token acquisition/intent because the handler
incorrectly parsed every persisted Microsoft Graph identifier as a GUID. Graph
defines federated-credential and app-role-assignment `id` values as strings, and the
live app-role assignment uses an opaque base64url-style ID. The handler now retains
GUID validation for actual object/client IDs and applies bounded URL-safe string
validation to those two resource identifiers. Neither failure issued a Registry
POST, created a Registry record, enqueued stage 7, or advanced the operation.

The corrected API is deployed on digest
`sha256:217b466a8820fd7479ceb0e75d88b0011002760fc0d144111bec8f3a7becfb74`.
Two subsequent controller preflights failed closed before opening a window because
the operator-side Azure CLI session returned Unauthorized for the exact retained
historical FIC GET. A clean interactive Azure CLI login refreshed the existing
administrator session without adding consent. Exact GET then matched retained FIC
`fea6b67c-008a-49aa-9672-6b98500d3d97`. Fresh SQL evidence passed, the worker was
narrowly rearmed on `ca-gateway-worker-dev-vnet--resume-20260827223855`, and the
controller opened one completion window bound only to the current operation, with
operator deadline `2026-08-27T22:54:36.6267911Z` and crash deadline
`2026-08-27T22:57:01.4389799Z`.

The signed-in Administrator confirmed exactly once. The create boundary returned an
ambiguous outcome before a Registry ID was durable, so the handler failed closed and
made the operation permanently non-replayable. The controller then closed admission;
Deactivate/Status restored the API and worker revisions recorded above. A final
zero-script SQL snapshot and queue readback proved no publishable outbox work and no
v3/v2/v1 queue-count change.

`src/ExternalAgent.Sample` is now a real bounded `net10.0` console client in the
solution. It accepts only public route inputs as arguments, reads the Gateway key
from non-echoing/redirected stdin, evaluates the configurable prompt before model
work, exits with safe decision evidence on block, and otherwise sends one activity
plus one receipt-bound AI interaction. It expects HTTP 200 for evaluation and HTTP
202 for both submissions and never renders dependency bodies. Earlier deployed
client/data-plane proof predates this prompt-protection revision; the new evaluation
sequence has local E2E proof only.

### Retained workflow-v2 canaries

Preserve these three failures exactly. They are historical evidence, not workflow-v3
inputs, and none may be retried, replayed, settled, purged, attached, or deleted.

1. Registration `637b600d-2c82-491d-b667-3c75108c1b2f`, operation
   `3c651663-505f-4bb5-bf2c-f240c080037c`, selected incompatible `pat-blueprint`
   and failed GET-only at `ResolveBlueprint` with
   `AGENT365_PLATFORM_ACCEPTANCE_UNCONFIGURED`. It made no Microsoft mutation.
2. Registration `ae197b30-0fe8-4d31-8300-dbac7cad3ec2`, operation
   `424808e5-db7d-4935-bc5d-9dc99b1fc12e`, selected compatible
   `simple-echo-agent Blueprint` (`76d144d9-7b6c-4448-b43f-76c1ae12cde5`). One FIC
   POST returned 201; an immediate stale list caused fail-closed manual state.
   Later read-only reconciliation found exactly one correct reusable FIC,
   `fea6b67c-008a-49aa-9672-6b98500d3d97`. It created no child, role, Registry
   record, or telemetry mapping.
3. Registration `b23cb073-912e-4efa-8a01-88a46b2af5fb`, operation
   `8ece1c62-df73-4185-8f73-7b27db080414`, external ID
   `agent-f3e843a9784f4700a6cb860c80286d67`, reused that FIC, created and verified
   child `8e4859bd-477c-4133-adb1-9030ec13bf5c`, and assigned OtelWrite. Its one
   application-authenticated Registry POST returned HTTP 500 without a durable ID.
   It remains manual at `RegisterAgent` (71%) and its create outcome remains
   unknown.

After MFA and explicit Admin Center Refresh, exact searches for the third canary's
display name and child ID each returned 0 of 341 agents. That is portal evidence of
no visible record, not API proof of no backend effect. Never issue another Registry
POST for this registration. Reconcile that historical outcome only through
read-only Registry/Admin Center evidence. Current workflow-v3 registrations use a
distinct registration, queue, delegated contract, and planned CLI-compatible ID;
they must not repair or reuse the v2 canary.

## Authorized next work

The complete development demo path is live: continuous registration, new or reused
blueprint, child Agent ID, delegated Registry completion, final token verification,
registration-bound Gateway ingress, Agent 365 transport, Admin Center visibility,
and blueprint-scoped prompt DLP. Preserve all safe mappings and every retained
failure artifact.

The next work is production hardening rather than another development canary:

1. run staging multi-replica, failover, rate-limit, and recovery tests;
2. capture a new read-only SQL snapshot if current database/outbox totals are needed
   for an operational change; do not present the older snapshot as current;
3. deploy and prove the implemented pre-model Prompt Shields/prompt-only Purview
   path in a separately authorized development change: additive migration, Content
   Safety resource/role, API/UI images, provider readiness, allow/block, receipt
   mismatch/consumption, and revised sample-client evidence; and
4. complete production privilege, HA, capacity, backup, retention, security, and
   incident reviews before any production rollout; and
5. review dependency updates in isolated, test-gated groups. The 2026-08-28
   currency scan found both same-major updates and deliberate major-version
   migrations; this synchronization does not silently change the proven runtime
   dependency graph; and
6. keep repository packaging lean. The unused 159.83 MB bundled `Python/` runtime,
   8.7 MB unused Bootstrap template assets, root build/restore transcripts,
   rendered Container App YAML, and hard-coded local launch wrappers were removed
   after reference checks found no current build, runtime, deployment, test, or
   documentation consumer. Operational evidence and incident records remain.

Retained-message disposition, historical Registry replay, resource deletion, SQL
finalization, and production rollout remain separately reviewed actions.

## Completion criteria and production blockers

The core development demo is complete: create-new and reusable-blueprint workflow-v3
registrations are Active, Entra mappings and Registry acceptance are durable,
Gateway-key binding is proven without disclosure, Agent 365 transport is accepted,
Admin Center landing is visible, and blueprint-scoped `uploadText` DLP blocks the
synthetic sensitive prompt. `downloadText` is currently offline and the completed-
pair route is not a pre-model response gate.

Production remains unclaimed because the Registry API is beta, Global-cloud only,
and unsupported for production; real multi-replica/failover/staging stress is
outstanding; Microsoft-resource deletion/reconciliation is unsupported; response-
side inline DLP is not implemented; and production privilege, HA, capacity, backup,
retention, security, and incident reviews remain separate.
The pre-model prompt-protection feature is source-complete but not part of the live
development proof until its additive migration, Azure resource/RBAC, deployed
revision, and bounded client canary are recorded.

## Repository and secret boundary

The synchronized repository checkpoint includes the intended source, tests,
documentation, agent definitions, skills, deployment assets, and bootstrap layer.
Preserve any later user or concurrent edits; never mass-clean or reset them. Local
build output, bootstrap state, machine settings, and private configuration remain
ignored and are not part of repository truth.

`.secrets` is authorized private runtime input. Authorized tooling may consume
required values through the existing non-echoing path. Never print, log, document,
alter, copy, transmit, or commit it. Never record clear Gateway keys, access tokens,
managed-identity assertions, authorization headers, or raw dependency bodies.

## Safe resume point

1. Read this file through the end and then read the latest
   [`operations/development-deployment-status.md`](operations/development-deployment-status.md)
   entry. Chat history, an open browser, and a local process are not handoff
   evidence.
2. Treat the Purview protection-profile and pre-model Prompt Shields implementations
   above as local, unreleased source until a separately authorized deployment is
   recorded. Their broad source gate is complete. The immediate live action remains
   none; the next authorized rollout must start with additive migration/resource/
   role/image preflight and preserve every deployed registration and retained item.
3. Preserve the three v2 registrations/messages, the reconciled FIC, child, and
   role. Reverify their retained queue baselines remain unchanged; never use the new
   v3 path to reconcile or mutate those artifacts.
4. Distinguish local source, any ephemeral local UI, and the continuous deployed
   development service. Preserve every current Active registration, its child/
   blueprint/Registry mapping, and safe credential boundary.
5. Admin Center landing and blueprint-scoped prompt DLP are confirmed. Resume with
   a separately authorized source-feature rollout or staging/multi-replica/failover
   and production-readiness work. Do not reinterpret offline `downloadText` as an
   inline response gate, claim Prompt Shields live from local tests, or use
   historical failures as retry inputs.
6. For a new subscription or deleted resource group, start at
   [`../bootstrap/README.md`](../bootstrap/README.md), run `Plan`, then use the
   resumable `Apply`. Do not substitute the old partial `tools/bootstrap.ps1`.
   Until one disposable clean-subscription run is captured, distinguish locally
   validated bootstrap source from a live-proven recovery path.
7. After every verified change, update this file and the deployment checkpoint with
   exact tests, digests, revisions, schema/recovery state, all queue/outbox counts,
   safe external identifiers, and the next action. Never record secret material.
