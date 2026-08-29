# A365 Gateway implementation status

This is the living cross-agent handoff. Read it with `AGENTS.md`, `CLAUDE.md`, the
relevant guide under `docs/agent-guides`, and the latest live evidence in
[`operations/development-deployment-status.md`](operations/development-deployment-status.md).

Last reconciled with the workflow-v3 working tree, continuous development
deployment, Microsoft 365 Admin Center landing, blueprint-scoped Purview DLP proof,
the local Phase 0–6 clean-subscription bootstrap hardening, the unreleased Purview
protection-profile source feature, and the live development Prompt Shields
deployment:
**2026-08-29**.

## Live development checkpoint: pre-model prompt protection

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

The complete local Release gate is **1,121/1,121**: unit 409, Admin UI 151,
end-to-end 106, security 111, observability/runtime 144, integration 92, and
architecture 108. Release build is zero-warning/error; format verification passes;
PowerShell parses 18/18; Bicep compiles 23/23 templates and validates 5/5 parameter
files; OpenAPI YAML and bootstrap JSON parse.

Prompt protection is now deployed and proven in the external development
environment. Private-network migration execution applied
`20260829_prompt_protection.sql` twice successfully and restored the SQL Entra
administrator immediately afterward. Content Safety account
`cs-a365gw-dev-s4a3t2` is in Korea Central with local authentication disabled; the
API managed identity has only Cognitive Services User at that account scope. Live
API revision `ca-gateway-api-dev--ps-20260829-0239` runs digest
`sha256:4b592efec95c6b3e415953ca3874f7863498d3e834e72b50d0c7162682fe8906`;
Admin revision `ca-gateway-admin-dev--ps-20260829-0241` runs digest
`sha256:06ee96a84962440fdede9f381c4d0ca18b84f9bcfd34a46d98f7259b77a248aa`.

Registration `ca5de6e3-d30a-4c57-8085-7382cc69fa0a` has Prompt Shields enabled.
A disposable managed-identity canary issued one temporary registration-bound key
in memory, received an Allowed Prompt Shields result plus Purview `AuditLogged`,
submitted activity/OTel and a receipt-bound interaction with HTTP 202, then
received HTTP 403 `PROMPT_BLOCKED_BY_PROMPT_SHIELD` for an injection prompt. Safe
correlations are `ce1d7832-6fa9-463f-b41c-53af013aa0a4`,
`1d116dc0-bfcc-4eff-8f15-ababe7f650cb`,
`759e4244-5475-4b19-9221-319ba8cca92a`, and
`b05a3b95-b4e8-4e80-a4e1-0f245ff506cb`. Temporary key
`7a275a31-7204-466a-9a1a-a37590a2ff4a` was revoked; its job, service principal,
and temporary API app-role assignment were removed. No clear key or token was
persisted or rendered. This is development proof, not a production-support claim
for the preview Agent 365 Registry dependency.

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

The current local increment hardens that unreleased runtime boundary further. The
worker treats only the exact persisted provider IDs and the persisted authorized
blueprint-application set as authority; it rejects extra scope, exclusions, bypass,
conditions/actions, unexpected policy modes, or incomplete collection/DLP/rule
readback. Temporary PKCS#12 material must be deleted with absence proven, and the
final workflow stage revalidates the exact Purview contract before a protected
registration can become `Active`. These are source and test claims only. No worker
revision, tenant policy, certificate, role assignment, or canary proves this newer
behavior in the live development environment.

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

The supported public surface is `./gateway` on macOS/Linux and `gateway.cmd` on
Windows. `gateway setup` hosts a temporary loopback-only Fluent UI; `gateway up`
provides the terminal path. Both delegate to the canonical
`bootstrap/bootstrap.ps1` state machine, whose Plan/Apply/Resume/Verify flow covers
the Azure foundation, Entra applications, typed Agent 365 seed blueprint, exact
workflow-v3 roles/consent/FIC, digest-pinned ACR images, empty-database
initialization, Admin UI, optional controls, and fail-closed readback.

The original one-command **Phase 0–6 plan is not complete**. A substantial local
candidate exists, but local source/tests are not release proof and must not be
reported as completion of the plan. The authoritative phase status is:

| Phase | Current status | Remaining boundary |
|---|---|---|
| 0 — Make the engine trustworthy | Partial | Schema/state/source binding, collision refusal, validators, Bicep compilation, and broad recovery tests are implemented. One live interruption after Prerequisites and exact-fingerprint Resume through Azure authentication is proven; an every-checkpoint interruption matrix and a completed disposable clean-subscription proof are still absent. |
| 1 — One cross-platform front door | Source complete; proof incomplete | `gateway`/`gateway.cmd` and the terminal command surface are implemented. The current candidate has not completed Windows, macOS Intel, macOS Arm, and Linux execution evidence. |
| 2 — Guided configuration | Partial | Quick Development, Staging Foundation, and Production-safe Foundation are implemented. The promised guided Connect Existing and Advanced profiles are not; existing-state import remains recovery-only and refuses unsafe adoption. Simulated Demo was explicitly optional-later and is absent. |
| 3 — Plan as a deployment contract | Partial | ARM What-If, the imperative manifest, accepted-plan/source binding, and post-deployment readbacks are implemented. Regional quota/SKU availability, global-name availability, and Agent 365 eligibility/licensing remain truthfully `NotChecked`, not proven preflight results. |
| 4 — Fluent progress and recovery | Partial | Structured redacted progress and safe diagnostics are implemented. Every error does not yet carry the complete requested mutation-occurred, retry-safe, exact-remediation, and resume-command contract. |
| 5 — Visual setup experience | Source complete; deployment proof absent | The loopback Fluent wizard and hosted Admin Setup Center are implemented and locally tested. The wizard combines the planned content into six steps, and this work has not deployed or authenticated the new Admin route. |
| 6 — Release-quality proof | Not done | Disposable-target runs accepted exact Plans and proved one deliberate interruption/Resume boundary. `a365gw6` reached 6/19, produced exactly one succeeded immutable build per component, and proved exact no-resubmit recovery. It also proved that Azure CLI emits no result object for `acr build --no-wait`, then exposed the inert call's empty worker-principal/manager-set PowerShell binding defects before ARM deployment. A completed corrected fresh-generation Apply/Verify, cross-platform matrix, authenticated Admin sign-in, new registration through `Active`, and bounded canary/revocation are still absent. |

The implemented Plan binds the full non-secret configuration, operation descriptor,
sanitized ARM What-If, deployment-affecting source, and a corroborated SQL bootstrap
client IPv4 into one canonical fingerprint. Plan accepts that IPv4 only when bounded
requests to ipify and AWS Check IP agree. Acceptance creates a content-addressed
execution snapshot under ignored `.bootstrap/accepted-source/`. Apply/Resume
requires the running checkout to match the accepted source, validates the snapshot,
then loads mutation modules, templates, scripts, project inputs, and ACR context
from those reviewed bytes.

Any durable step/output prevents a later Plan from mixing a different source
generation into that deployment state. Each step stores its source fingerprint,
and reusable checkpoints require independent exact provider readback. Image build
evidence, resource-group deployments, and API/worker/Admin UI resources bind the
same accepted fingerprint, deployment-ownership ID, and immutable image references.
Fresh state rejects a pre-existing resource group or managed identity instead of
adopting a same-name resource.

Every Apply/Resume rechecks authentication and pins every supported Azure CLI/ARM/
Graph call to the exact reviewed tenant and subscription instead of trusting a
mutable CLI default. `-NonInteractive` refuses a missing human Agent 365 or Purview
authorization handoff. Final verification always reruns; no cached verification is
accepted as deployed truth.

Database setup opens only one disclosed temporary network window. The firewall
rule's start/end address must equal the Plan-reviewed/stored IPv4. The exact rule is
then deleted with absence read back, and SQL public access is restored to `Disabled`
and read back; an unproven cleanup preserves a safe recovery record and fails the
step. Initialization accepts only zero user tables, then compares the complete EF
table/column/index contract and rejects extra programmable objects, principal
authority, schema/role ownership, or lookalike/partial state.

Key Vault authority is secret-scoped: the Admin UI user-assigned identity receives
Key Vault Secrets User only on its exact Entra client-secret resource; the worker
receives that role only on the exact configured Purview certificate-secret resource
when protection-profile automation is enabled; the API has no shared-vault role.
Verification proves the expected assignments and rejects wider or extra authority.

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

The corrected 2026-08-30 Phase 6 candidate gate passes at source commit
`715bbf93dcefa95266f1ce7616f8d39ca137fa10`. The Release solution build has zero
warnings and zero errors. Direct Release tests are **1,279/1,279**: unit 478,
Admin UI 155, local Setup 75, observability/runtime 149, integration 92,
end-to-end 106, architecture 113, and security 111. Pester discovered **267** tests:
**266** passed, none failed, and one Windows-only launcher test was skipped on macOS.
The canonical bootstrap source gate parsed **16** PowerShell files and **2** JSON
contracts and compiled all **23** Bicep templates. `dotnet format
--verify-no-changes` and `git diff --check` pass. The repository has **55**
Markdown files and **58** repository-local links with no broken target.

The loopback Setup UI was also inspected at 1280x720 and 390x844 with no horizontal
overflow. When the existing ignored `bootstrap/config.json` could not be safely
imported, the wizard displayed the protected-file warning, disabled Start, and did
not overwrite the configuration. The first disposable-target Apply attempt on the
earlier source generation completed local Prerequisites and then failed at Azure
authentication before any provider/resource/Entra/SQL/Agent 365 mutation. Its
state/evidence is preserved.

The next isolated `a365gw2` execution accepted Plan
`sha256:b062c6eb03899e2e902e1d92a7db33d5b0addcc73ce15c1712bf06b04296ec28`
for subscription `6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`, resource group
`rg-a365-custom-gw-phase6`, and deployment ownership
`967d17d1-e0f5-494b-bae7-0e1f00faff5c`. What-If contained exactly six Creates
and no Deletes. Apply completed Prerequisites, was deliberately interrupted as
Azure authentication started, then Resume recomputed and accepted the same Plan
fingerprint. Provider registration, the Azure foundation, and Gateway API identity
completed. The run stopped safely at **5/19** before an ACR build because Azure CLI
2.89.1 returns a nonzero missing-tag result for `acr task list-runs --image` on a
fresh empty registry instead of the expected empty array. Registry
`acra365gw2devg6gn55` still had no repositories, no task runs, and no persisted
image intent. The source-bound state, accepted snapshot, resource group, and Entra
application remain preserved; they must not consume a different source generation.

Commit `9b229434f4578a68fc8c60029838d30e133a1b93` fixes that discovered boundary:
absent exact tags do not invoke image-filtered run discovery, while a durable
`RunQueued` checkpoint is polled through exact `acr task show-run --run-id`
readback with strict output/digest validation and no automatic resubmission of an
unknown `IntentRecorded` outcome.

The resulting isolated `a365gw3` Plan
`sha256:16bcceb1a065ed2ab7b4fa86ae668048c3e79aca9cd7927e1c4a564d22724eaf`
again contained exactly six Creates and no Deletes for
`rg-a365-custom-gw-phase6b`. Apply reached 5/19 and submitted exactly one API image
build before the next live contract mismatch: Azure reports an `az acr build`
execution as `QuickRun`, not the source's `QuickBuild`. State had durably recorded
only the pre-mutation API intent, so it did not claim the rejected run ID and did
not submit again. Exact run `de1` subsequently succeeded with one `gateway-api`
digest; no worker or Admin UI build was submitted. The source-bound `a365gw3`
state/snapshot and its foundation/API identity remain preserved.

Commit `00018600b8b1bdd466f16ab28a66b58348b82a0b` now requires `QuickRun` consistently
for submission, exact tag discovery, durable run-ID polling, and final immutable
image verification; `QuickBuild` and both automatic run types fail closed. The
next isolated project was `a365gw4-dev`, resource group
`rg-a365-custom-gw-phase6c`, ownership
`ced0c22f-ba7a-491c-8c25-38d76a55e7a8`, and ACR
`acra365gw4dev6hdqn4` in disposable target subscription `internal-security-lab-02`
(`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`). Its initial accepted Plan
`sha256:21efe30b101e5092bb03d8547d50f08af88c0fcc6e138fbae69ead5d59d7c626`
bound configuration
`sha256:a45df6a92e10fe39c1bb5330b76c5f210c62aaba0175e627353d680c68e16cdb`
and source
`sha256:e13454d6d3258d8a6ac216c1bf7b92c237fc8fd1ec34bdbdff7a95b9aeac3af9`;
authenticated What-If reported exactly six Deploy actions and zero Delete actions.

Apply completed 5/19 and stopped in immutable images after recording API intent
`30bac341-4ef9-414b-bce1-499bb9efda8d`. At this checkpoint the failure was
interpreted as a sparse `az acr build --no-wait` scheduling receipt being validated
as a full run record; the later `a365gw6` investigation below supersedes that
interpretation. Exact readback showed API run `de1` succeeded as `QuickRun`
with digest
`sha256:3c65a6903a5cb3b95ee314d7bf495d4675ee777fb4816747e6e651e4fa327980`.

A fresh Resume Plan
`sha256:5caa84429699de696f9e3bb305913933158aa6683ab0209bfd380331e4611aa0`
kept the same configuration, source, ownership, and six-Deploy/zero-Delete
contract. Resume exactly recovered and digest-checkpointed the API image, recorded
worker intent `bafe753a-62e0-4f2d-8f59-69d75053b58c`, submitted exactly one worker
build, and stopped on the same then-unresolved submission-result defect. Exact run `de2` subsequently
succeeded as `QuickRun` with digest
`sha256:6d5743b68ed84d8a6016c8b66d18caea0481cfe764aeb27d48a77836b77bb3d0`.
Bootstrap state remains API `DigestCheckpointed` and worker `IntentRecorded`.

No Admin UI build, SQL initialization, Agent 365 blueprint, runtime, Service Bus
queue/outbox, registration, canary, Gateway-key issuance or revocation, or Purview
action occurred. Preserve this attempt and do not Resume it with edited source.
Commit `3ad90d764bbd64acc778c24b0b09c0ff02be564e` accepts only the exact
one-property run-ID submission receipt, persists `RunQueued` before polling, and
then validates `QuickRun` and output through exact `show-run` readback. Focused ACR
tests pass 21/21; the complete Bootstrap suite passes 230 with zero failures and one
pre-existing macOS skip. Both changed PowerShell files parse, `git diff --check`
passes, and independent review found no P0/P1/P2 issue. The next live action is
fresh isolated project `a365gw5` in absent resource group
`rg-a365-custom-gw-phase6d`; no `a365gw4` Resume is authorized with the changed
source.
Protected subscription `95bedc30-f6ac-481b-a3a6-588d2883c216` was not selected,
mutated, or used for this proof. No new bootstrap runtime, queue/outbox, or Purview
behavior is live-proven yet.

The next isolated generation, `a365gw5-dev`, started from absent resource group
`rg-a365-custom-gw-phase6d` and absent bootstrap state. Ownership is
`06bba549-69ba-474b-97e7-100cdc31a4fa`; ACR is `acra365gw5devtn2ykh`.
Its accepted Plan
`sha256:ffc845dc08b140faf9e81362de3fc22d6cfab74000fd119f5a80e9cd19faaa98`
bound configuration
`sha256:40da086f6562c28b29a1c7a414ab3f35e806ef5b85c88693761208be2c6a509e`
and source
`sha256:2936dcb8ad1d742304a571717f0c7d48ae2c4d54074725fc5244a2043e7ad493`;
authenticated What-If reported exactly six Create actions and zero Delete actions.

Apply completed 5/19, recorded API intent
`396d698d-2968-4714-956a-cf8be964e9c8`, submitted exactly one build, and stopped
before `RunQueued`. Exact run `de1` succeeded as `QuickRun` with `gateway-api`
digest
`sha256:375361ec21424dbb038c409ea018b96e0cc34c9e2926ee81803429e95b361fdd`,
while bootstrap state remains `IntentRecorded`. Commit
`3ad90d764bbd64acc778c24b0b09c0ff02be564e` had introduced a run-ID-only
projection based on the then-current receipt hypothesis. This attempt proved that
the shared runner merged the queued-build stderr notice into the parsed value;
`a365gw6` later proved the CLI returns no result object or JSON stdout for this
`--no-wait` command.

No worker or Admin UI build, SQL initialization, Agent 365 blueprint, runtime,
Service Bus queue/outbox, registration, canary, Gateway-key action, or Purview
action occurred. Preserve `a365gw5` and do not Resume it with edited source. A
targeted stdout-only receipt boundary is implemented in commit
`a165519df704fdeb30dae7092f8f88cd4a89b22f`. It discards stderr without disk
persistence, preserves fixed redacted exit-code handling even when the caller
enables native error promotion, and is used by exactly the ACR no-wait scheduling
receipt. Focused tests pass 87/87; the complete Bootstrap suite passes 234 with zero
failures and one pre-existing macOS skip. All four changed PowerShell files parse,
`git diff --check` passes, and independent review found no remaining issue.
Protected subscription `95bedc30-f6ac-481b-a3a6-588d2883c216` remains unselected
and unmodified, and its queues/messages were not accessed. The next live action is
fresh isolated project `a365gw6` in absent resource group
`rg-a365-custom-gw-phase6e`.

Fresh generation `a365gw6-dev` then started from absent resource group
`rg-a365-custom-gw-phase6e` and absent state in only disposable target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Ownership is
`b354e365-48f9-4255-bb98-4f6222e192e7`; ACR is
`acra365gw6devkgafft`. Initial Plan
`sha256:462a3cf947f0bd3be3a03f9ad7ed71e94f0a2c2aa629c68db021e30c09ed07cf`
bound configuration
`sha256:cc58aa76fd5b1bfd2556ae19a9e0df61f4f9ee862f189986b105814b2169f85e`
and source
`sha256:93dbe20bb0dcf061fb6f01fe07b4d9eef73fb146578fb5c4dc3db80ee591ccfe`;
What-If reported six Creates and zero Deletes. Foundation and Gateway API identity
completed.

The first API build recorded intent
`9c351f63-7b39-4d83-8d26-05ade97264fb`, submitted once, and stopped before
`RunQueued`. Exact local Azure CLI 2.89.1 source inspection proved that the invoker
sets every `supports_no_wait` command result to null when `--no-wait` is present,
after the handler schedules the run. Therefore the presumed stdout receipt cannot
exist; stderr separation was correct. Exact API run `de1` succeeded as `QuickRun`
with digest
`sha256:2cf9d8f03d4d5b9ac3fbb14265f526229b2927e990109cbacdc72ca773d47cbb`.

Resume Plan
`sha256:da4bb058ab387b4ac1736abb2d109c4d376bbb0fef93bb808447001d266b599e`
kept the exact configuration/source/ownership boundary and reported six Deploys,
zero Deletes. Three bounded Resumes recovered each prior intent by its unique exact
tag without resubmission. `Immutable workload images` completed with exactly three
succeeded `QuickRun`s: API `de1` at the digest above; worker `de2` at
`sha256:3f8ffaa95b0546090c5e49987899001657bccd1f25a15edeef5263200698f2e1`;
and Admin UI `de3` at
`sha256:da6f12c8383bc5be015157b11ff88ba65d3aba476975650824eadcfbd3236b45`.
The live result proves exact crash recovery and no duplicate builds, while also
disproving the receipt-producing CLI assumption.

The next step stopped safely at **6/19** before any inert group deployment. The
inert call's intentionally empty worker principal and `managerApplications` set
were passed to mandatory PowerShell parameters that did not allow those initial
empty values; independent binding reproductions returned
`ParameterBindingValidationException` for each. Both intended
Container Apps and the inert deployment remain absent. No SQL initialization,
Agent 365 blueprint, workflow identity, Service Bus queue/outbox, runtime, Admin UI,
registration, canary, Gateway-key action, or Purview action followed. Preserve the
source-bound `a365gw6` state, snapshots, foundation, API identity, three images, and
failed step; never Resume it with edited source. The next action is the reviewed
no-result ACR scheduling/discovery fix plus initial-only empty identity-input fixes,
complete local verification, and a new isolated generation. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated, and no
retained queue/message was accessed.

Commit `715bbf93dcefa95266f1ce7616f8d39ca137fa10` implements and independently
reviews that correction without touching live Azure state. A fresh build now uses
one stdout-isolated `az acr build --no-logs`, accepts only its exact succeeded
`QuickRun` projection, checkpoints the run ID, and independently revalidates the
run plus immutable tag/digest. Recovery scans a bounded registry-wide projection
for the unique intent tag, requests a 101st truncation sentinel, and fails closed
on truncation, ambiguity, terminal failure, or an unknown recovered submission;
it never automatically resubmits that outcome. Initial deployment accepts only the
intentional empty worker/manager authority inputs and rejects database, activation,
Purview, or Admin UI runtime inputs before Azure access. Runtime deployment binds
the canonical worker principal exactly to ownership/source-bound database evidence.

The same commit maps the real ARM output `agent365RegistryProvider` to normalized
evidence `registryProvider`, replaces positional string-array preflight splatting
with one named hashtable that preserves the manager-ID array, and verifies the
explicit continuous-development contract. Security-critical Registry/admission
environment settings must now be one plain value in exactly one container;
case-conflicting duplicates, missing values, secret references, mixed continuous/
exact inputs fail closed, and exact registration/delegated-action windows are
exercised only as independent states. Focused regression tests pass **103/103**,
the architecture suite passes **113/113**, the complete Pester gate passes **266**
with the one macOS skip, and
independent settled-diff review found no actionable issue. The next live action is
a new isolated `a365gw7` generation in absent resource group
`rg-a365-custom-gw-phase6f` in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`; `a365gw6` remains frozen evidence and the
protected running subscription remains outside the proof.

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

Queues are v3 `0/0/10`, retained v2 `0/0/3`, and historical `0/0/2`. The prior
ninth v3 DLQ is the preserved first create-new propagation failure. The additional
retained v3 entry was not accessed or disposed during this deployment and its cause
must not be inferred without a separately authorized evidence review. The latest exact SQL artifact,
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

`src/ExternalAgent.Sample` is a real bounded `net10.0` console client in the
solution. It accepts only public route inputs as arguments, reads the Gateway key
from non-echoing/redirected stdin, evaluates the configurable prompt before model
work, exits with safe decision evidence on block, and otherwise sends one activity
plus one receipt-bound AI interaction. It expects HTTP 200 for evaluation and HTTP
202 for both submissions and never renders dependency bodies. The live disposable
managed-identity canary exercised the same evaluation, receipt-bound interaction,
activity/OTel, safe block, and credential-revocation contracts. An external user
can exercise `ExternalAgent.Sample` after issuing a new one-time registration key;
the clear value is never stored by the Gateway or documentation.

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
3. run staging/provider-outage and negative receipt tests against the deployed
   Prompt Shields path, including fail-closed dependency behavior, expiry,
   cross-registration mismatch, and multi-replica consumption; and
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
Pre-model Prompt Shields is live and proven in development. Production remains
unclaimed until the staging, multi-replica, dependency-outage, privilege, capacity,
and incident reviews above pass; the preview Agent 365 Registry dependency also
prevents a supported production claim.

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
2. Treat Purview protection profiles as local, unreleased source. Prompt Shields is
   deployed and proven in development on the exact resource, revisions, registration,
   and safe correlations recorded above. Preserve that evidence and do not conflate
   development proof with supported production readiness.
3. Preserve the three v2 registrations/messages, the reconciled FIC, child, and
   role. Reverify their retained queue baselines remain unchanged; never use the new
   v3 path to reconcile or mutate those artifacts.
4. Distinguish local source, any ephemeral local UI, and the continuous deployed
   development service. Preserve every current Active registration, its child/
   blueprint/Registry mapping, and safe credential boundary.
5. Admin Center landing, blueprint-scoped prompt DLP, Prompt Shields allow/block,
   receipt-bound submission, and activity/OTel acceptance are confirmed. Resume
   with the unreleased protection-profile rollout or staging/multi-replica/failover
   and production-readiness work. Do not reinterpret offline `downloadText` as an
   inline response gate or use historical failures as retry inputs.
6. For a new clean subscription, start at
   [`../bootstrap/README.md`](../bootstrap/README.md), run `Plan`, then use the
   resumable `Apply`. Preserve the exact checkout/source fingerprint and accepted
   snapshot for Resume; never mix durable state across source generations. Do not
   substitute the old partial `tools/bootstrap.ps1`. Preserve `a365gw6` at 6/19;
   it live-proves exact image-build recovery but cannot consume edited source. The
   next clean-subscription action is a new isolated generation after the ACR
   no-result scheduling/discovery and inert empty identity-input fixes pass the
   complete local gate. Until one disposable run completes Apply/Verify,
   distinguish locally validated corrected source and partial live recovery proof
   from a completed bootstrap. If a completed resource group was
   deleted, preserve state and use a separately reviewed disaster-recovery decision;
   bootstrap intentionally refuses automatic tenant-object/credential replay.
7. After every verified change, update this file and the deployment checkpoint with
   exact tests, digests, revisions, schema/recovery state, all queue/outbox counts,
   safe external identifiers, and the next action. Never record secret material.
