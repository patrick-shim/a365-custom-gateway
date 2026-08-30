# A365 Gateway implementation status

This is the living cross-agent handoff. Read it with `AGENTS.md`, `CLAUDE.md`, the
relevant guide under `docs/agent-guides`, and the latest live evidence in
[`operations/development-deployment-status.md`](operations/development-deployment-status.md).

Last reconciled with the workflow-v3 working tree, continuous development
deployment, Microsoft 365 Admin Center landing, blueprint-scoped Purview DLP proof,
the local Phase 0–6 clean-subscription bootstrap hardening, the unreleased Purview
protection-profile source feature, and the live development Prompt Shields
deployment:
**2026-08-30**.

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
| 6 — Release-quality proof | Not done | Disposable-target runs accepted exact Plans and proved deliberate interruption/Resume. Generations `a365gw6` through `a365gw17` exposed and bounded the image, identity, ARM-readback, recovery-graph, PowerShell, and provider-managed-resource defects recorded below. `a365gw18` then repeated the exact steps 1–10 prefix and proved the tenant management-group policy keeps SQL public network access `Disabled`; step 11 failed safely before any firewall, migrator, schema, Admin, runtime, registration, Registry, key, or canary action. The corrected candidate replaces that incompatible public path with one VNet-private, retry-disabled Container Apps Job and is locally reviewed only. A fresh `a365gw19` Apply/Verify, cross-platform matrix, authenticated Admin sign-in, new registration through `Active`, and bounded canary/key-revocation proof remain absent. |

The implemented Plan binds the full non-secret configuration, operation descriptor,
sanitized ARM What-If, and deployment-affecting source into one canonical
fingerprint. The retained `sqlBootstrapClientIpv4` field is legacy schema metadata
fixed to `0.0.0.0` and is unused by the supported private database path. Acceptance
creates a content-addressed execution snapshot under ignored
`.bootstrap/accepted-source/`. Apply/Resume
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

Database setup keeps SQL public network access `Disabled` and requires zero firewall
rules. It deploys a dormant, digest-pinned GA manual Container Apps Job inside the
VNet-integrated environment, persists a non-secret execution-intent receipt before
the sole authorized start, temporarily assigns the Job identity as the singular SQL
Entra administrator, and restores the exact original administrator after the exact
execution settles. Resume adopts exact dormant or execution state and never starts
a second execution after an unknown outcome. Initialization accepts only zero user
tables, reconstructs exactly three intent-bound evidence records from the exact Log
Analytics stream, compares the complete EF table/column/index contract, and rejects
extra programmable objects, principal authority, schema/role ownership, or
lookalike/partial state. Final verification also requires the Job identity to have
zero Azure RBAC and zero Microsoft Graph application-role assignments.

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

The baseline Phase 6 candidate gate passed at source commit
`1cdd5eb2deaefa3ba6989308566806f0920c2305`. The Release solution build has zero
warnings and zero errors. Direct Release tests are **1,304/1,304**: unit 479,
Admin UI 155, local Setup 75, observability/runtime 149, integration 92,
end-to-end 106, architecture 115, and security 133. Pester discovered **369** tests:
**368** passed, none failed, and one Windows-only launcher test was skipped on macOS.
The canonical bootstrap source gate parsed **19** PowerShell files and **2** JSON
contracts and compiled all **25** Bicep templates plus **5** parameter files. Focused
terminal-deployment recovery passes **70/70**, existing-deployment image-pull
compatibility passes **23/23**, the bounded canary lifecycle/state gate passes
**27/27**, and its exact Microsoft identity/evidence subset passes **22/22**.
Independent settled-diff reviews found no blocking issue. `dotnet format
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

Fresh generation `a365gw7-dev` used resource group
`rg-a365-custom-gw-phase6f`, deployment ownership
`9593d817-e3ea-4643-ae49-e15dbfaaede6`, and ACR
`acra365gw7devv47vkw`, exclusively in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Its accepted Plan
`sha256:0b1abe3e43efb282bd38070106aa8f8dae53dc2234e8f2b45b7d440e08c115aa`
bound configuration
`sha256:233278aa4965c14ffa7b5615df06edee7d0a9a65716c1877cf8ed29166fc6f79`
and source
`sha256:be92f53543729e6a467500db73dc4165c0f22e62762c05b758ad5edf992958ab`;
authenticated What-If reported exactly six Create actions and zero Delete actions.
The Gateway API application object/client/service-principal IDs are respectively
`2d33d7eb-8a70-4ace-a79f-567cbbb3f6b2`,
`722bb149-4e34-4d61-bd05-6778af55f7ca`, and
`26e140fc-ae19-4fb1-889c-857128d01b28`.

Apply reached **6/19** with exactly three succeeded immutable `QuickRun`s: API
`de1` at digest
`sha256:c6c5ad170b1de22460f2407d75aea1bd66f9c7502c009ac6b163b1cb92345752`,
worker `de2` at
`sha256:9db329085a8c3be1bc85d684be9cf183742ce41a45e6d9970bf1ab07f858550a`,
and Admin UI `de3` at
`sha256:197ecf9594670c819c39a6b1b8f60914aeda713e405ed69819af0bf225aee34e`.
Inert deployment `a365gw-a365gw7-bootstrap-inert-dev` reached terminal `Failed`
at `2026-08-29T19:32:39.849702+00:00`. Dependency modules created the reviewed
foundation resources, but `deploy-worker-app` failed. The API app remains absent;
the partial worker app `ca-gateway-worker-dev-v3` is failed with no revision and
system-assigned principal `57fbc79c-fcc9-44a3-9395-c82efd1a3d7f`. Bounded
operation readback isolated the defect to the first private-ACR pull: the workload
system identity could not receive `AcrPull` until after the app existed, while the
app could not provision its first revision without pulling the image. No provider
body was emitted or persisted. Safe diagnostics are preserved at
`.bootstrap/diagnostics/a365gw7-dev-20260829-193316.json`.

No runtime activation, SQL initialization, Agent 365 blueprint, workflow identity,
Admin UI, registration, canary, Gateway-key issuance/revocation, Registry, or
Purview action completed. Preserve the `a365gw7` state, accepted snapshot, Entra
application, three image digests, shared foundation, terminal deployment, and
partial worker identity. Never Resume it with changed source, and do not treat its
failed worker as a new workflow input. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated; its
queues/messages were not accessed.

Commit `16138105ecf9a05deed2c275b39e4f850a10f924` corrects this boundary without
changing live state. Clean bootstrap now creates one source/owner-bound user-
assigned pull identity, grants only the deterministic ACR-scoped `AcrPull` role,
and enables ACR managed-identity ARM-audience authentication before either
workload app. API and worker retain their system identities for runtime authority
but use the dedicated identity for registry pull. Terminal `Failed` or `Canceled`
same-name Incremental deployments can be retried only after exact source, owner,
mode, parameter, partial-app, and durable-checkpoint validation; nonterminal,
unknown, or drifted state fails closed. Existing-deployment tooling requires either
an explicitly authorized exact historical system-identity contract or an already-
migrated exact dedicated-identity contract; it performs no identity migration,
role deletion, or cleanup.

The corrected source passes the complete gate recorded above. The next live action
is a new isolated `a365gw8` generation in absent resource group
`rg-a365-custom-gw-phase6g`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. `a365gw7` is frozen evidence, not a Resume
candidate.

Fresh generation `a365gw8-dev` used resource group
`rg-a365-custom-gw-phase6g`, deployment ownership
`e7aa5755-7e7f-448c-a7ef-92dadc054235`, and ACR
`acra365gw8devphvcbm`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Its initial accepted Plan
`sha256:8668df4700ca605e941adf7c455f4cf8e0fa568178d116542e0c450d3491417e`
bound configuration
`sha256:17b21308b8e58d78f2c8dab53775af91843157c128bf4ee8082fbec92947c37f`
and source
`sha256:eddc62123a1ee6d8d68540d0f5b560485c30d02a1a3f6c9a55e6bb0705b91c86`;
authenticated What-If reported exactly eight Creates and zero Deletes. Apply was
deliberately interrupted after Prerequisites and Azure authentication durably
completed at **2/19**, before provider or resource mutation. Persisted status
reported `Paused`, 10%, and Azure provider registration as the exact next step.

Resume recomputed the identical Plan and completed provider registration. The
subscription-scope foundation deployment then succeeded at
`2026-08-29T20:47:03.973590+00:00`. It created the dedicated pull identity
`id-gateway-runtime-pull-dev`, principal
`28533d8c-e205-424e-b4f1-6457a47f1731`, and deterministic ACR-scoped role
assignment `97063172-3842-5639-a570-9f50dfd5586e`. Bootstrap nevertheless stopped
at **3/19** because its strict post-deployment validator used Azure CLI 2.89.1's
typed `az acr show` projection, which returned null for
`azureADAuthenticationAsArmPolicy`. Exact generic ARM readback at the deployed
`2023-11-01-preview` API returned `enabled`; identity, assignment, ownership, and
source fields also matched. The recovery Plan
`sha256:0a2ef13a962f3499cdc379c2eec7d84c511bee5bf7ac8511a470240a2d2a3f5b`
reported exactly eight Deploy actions and zero Deletes, but exact recovery failed
closed on the same incomplete typed projection without replaying the deployment.
Safe diagnostics are preserved at
`.bootstrap/diagnostics/a365gw8-dev-20260829-204735.json`.

No Gateway API identity, image build, Container App, SQL initialization, Agent 365
blueprint, workflow identity, Admin UI, registration, canary, Gateway-key,
Registry, queue/message, or Purview action followed. Preserve the `a365gw8` state,
accepted snapshot, succeeded foundation deployment, ACR, pull identity, and role.
Never Resume it with changed source. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated, and its
queues/messages were not accessed.

Commit `78ef1c0fc5b81005a9ec56c4adde044ed6aeb900` replaces all three ACR ARM-audience
policy checks with exact full-resource-ID, target-subscription reads pinned to the
same `2023-11-01-preview` ARM API used by Bicep. The validator still rejects absent
properties, disabled policy, API failure, wrong resource ID, or ownership/source
drift. Independent review found no blocking issue, and the complete local gate is
recorded above.

Fresh generation `a365gw9-dev` used resource group
`rg-a365-custom-gw-phase6h`, deployment ownership
`fc045585-0296-4e3c-a27f-00c3aa017f59`, and ACR
`acra365gw9devisqxpa`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Its initial accepted Plan
`sha256:1bc13d8f4b4c8b412308ae91de6b5440506aa9f68f7f1f8cdc799c7edbb09df9`
bound configuration
`sha256:7dd28b4a5c9c9589cb2c179630e4179fa183a7b242749ab69f54ab70a27c9c87`
and source
`sha256:ff0fe552aa52f478cb8cfc08a126f1e4f76a13f4bc9e222ae9c1c3545a067b4f`;
authenticated What-If reported exactly eight Creates and zero Deletes. Apply
completed Prerequisites, exact Azure authentication, provider registration,
foundation, Gateway API identity, and all three immutable images. The dedicated
pull identity principal is `7aabeaf0-c67c-4d82-8cda-28733920b934`, with exact
ACR-scoped `AcrPull` assignment `3e3bf721-f4b6-5140-8d54-8af36b559a4f`.
Succeeded `QuickRun`s are API `de1`
`sha256:a204d6a54b95fab7cc5b9edc03772aecec77a301e63a756a1a35daaf57de1bba`,
worker `de2`
`sha256:d9a6822a9262156e1501166133071468d550bf6e18494534c4bd023664f858e6`,
and Admin UI `de3`
`sha256:168987bba384b9e053cd948c9fbced45b3ee7eb07fb340c1c4717c2af9fb9ded`.
Gateway API application object/client/service-principal IDs are respectively
`e4240e2f-e0d0-40aa-80d7-d6ba85b43388`,
`107b5119-fa96-44af-9b39-3aae9fc65c0e`, and
`b9fe7e69-4305-40c8-b16e-2bd06caed702`.

Bootstrap stopped safely at **6/19**, 31%, before the inert ARM deployment. The
local guard still required the v2 access-token audience to equal the custom
Application ID URI, while Entra correctly returned the project-scoped scope URI
and the bare API client ID as distinct values. Safe diagnostics are preserved at
`.bootstrap/diagnostics/a365gw9-dev-20260829-211549.json`. No Container App,
database initialization, Agent 365 blueprint, workflow identity, Admin UI,
registration, canary, Gateway-key, Registry, Service Bus queue/message, or Purview
action followed. A later recovery Plan
`sha256:655ecacf57bf726a9bb999436c816fab38d6cf807f9d7d622231ed283878a2ca`
was accepted before the source correction and is also frozen; neither Plan may be
resumed with changed source. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated, and its
queues/messages were not accessed.

Commit `1cdd5eb2deaefa3ba6989308566806f0920c2305` makes the Entra scope base URI and
v2 bare-client-ID token audience explicit and independently verified across Bicep,
API, worker, Admin UI, and preflight. It also adds a reviewed bounded interactive-
user canary with durable per-mutation recovery, exact token/registration/key
binding, reverse-order exact Entra cleanup only after proven key revocation, and
truthful minimal-profile behavior. The next live action is a new isolated
`a365gw10` generation in absent resource group `rg-a365-custom-gw-phase6i`, only
in the target subscription. `a365gw8` and `a365gw9` are frozen evidence, not Resume
candidates.

Fresh generation `a365gw10-dev` used resource group
`rg-a365-custom-gw-phase6i`, ownership
`c388ba75-6a77-45b7-a2d2-e3c4bce8e99d`, and ACR
`acra365gw10devg6eltw`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Accepted Plan
`sha256:f83b11d238e722ca3396a390a9fa0802f3f55ba7e29dba1f4413536dfb734c0c`
bound configuration
`sha256:c1847f79831db3c1ea1dec85e6c3f1a3b9e0b05f9a2632a81895f65a76ee6f01`
and source
`sha256:a2f22eda691af86fc61cac1bd1e3309382520ed6a9b246736dbdc5df9b6a4c6b`;
authenticated What-If reported exactly eight Creates and zero Deletes. Apply was
deliberately interrupted after Prerequisites and exact Azure authentication reached
**2/19**, 10%. Status reported `Paused`; Resume recomputed the identical Plan and
revalidated both checkpoints before continuing. This is live proof of the intended
same-source interruption boundary.

Resume completed provider registration, foundation, Gateway API identity, and all
three immutable images. Pull identity principal
`ee85af3d-8fc0-4d94-9666-430519dcbd20` has deterministic exact ACR-scoped role
assignment `e0f5a084-0f56-5b8b-8cd6-9aa93d50e856`. API, worker, and Admin UI
`QuickRun`s `de1`, `de2`, and `de3` produced digests
`sha256:6a44f3fbe718d4f050c487cc13ad9ca9bab645c2c6b16bd12a2b9bbd68909861`,
`sha256:247d7257736cfb2ca8dcc0a30403f01e707146b02361fd216305b4fcebdd6171`,
and
`sha256:e5c5bf8328ea682ccb1650d67e82cbc88e41857b77fe22f3a79e7448cbff7113`.
Gateway API application object/client/service-principal IDs are respectively
`9798e855-f286-4315-b798-1cead0df0c0d`,
`26c59e63-a339-419b-bbb5-0e5701ba869f`, and
`ac862a1a-6109-4503-a8b3-0d97af9d2c74`. The scope base URI is
`api://a365-gateway-a365gw10-dev`; its separately persisted v2 token audience is the
bare API client ID above.

The inert top-level deployment and every observed nested deployment reached
`Succeeded` under correlation `b283f5b9-f9b4-4b93-ac78-05371854a3df`, but bootstrap
failed during immediate strict post-deployment validation and preserved **6/19**.
No database initialization, Agent 365 seed blueprint, workflow identity, Admin UI
identity/credential deployment, runtime activation, registration, canary,
Gateway-key, Registry, or Purview action followed. A read-only recovery Plan
`sha256:8aafa9d8ea77535dcfdbff7b0df00f65ece3d1a9d2a3cbc8065219c14f35ca6e`
reported eight `Deploy`, twenty-five `Ignore`, and zero `Delete` changes. The current
validator rejected every `Ignore`, so the Plan was not apply-ready and its earlier
acceptance was correctly cleared. Microsoft documents `Ignore` as an existing
resource absent from the current desired template that will not be deployed or
modified; the observed ignored set is the exact target-resource-group surface from
the succeeded inert graph. Expansion-limit ambiguity means the bootstrap must add
a bounded, state-aware fail-closed rule rather than permit `Ignore` globally.
Preserve `a365gw10`; never reconstruct acceptance or Resume it with changed source.
Protected subscription `95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected
nor mutated, and its queues/messages were not accessed.

Commit `bb001483bae0577d7c29a9638c1c7275dae44525` implements the reviewed bounded
recovery contract without making `a365gw10` resumable under edited source. Plan
contract v3 fingerprints the complete recovery boundary. `Ignore` is accepted only
for exact-case `Ignore` predictions when persisted source, configuration, ownership,
completed prefix, and absence of later phases all match; live GET-only readback must
then prove the exact sorted 25-resource inert graph, Succeeded Incremental deployment,
76/76 readable ARM parameter parity, deterministic tags, type inventories, alert and
dependency relationships, the generated private-endpoint NIC reverse binding, and
the SQL `master` parent binding. Fresh, malformed, mixed-case, duplicate,
cross-type, out-of-group, expanded, Prompt-Shields-enabled, or provider-drifted
surfaces fail closed. Read-only recovery has no ARM mutation path, and every Azure
read remains pinned to target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76` by the shared command boundary.

A sanitized GET-only smoke against frozen `a365gw10` proved all 25 resources and
boundary fingerprint
`sha256:48adf18a485c1fa2a4ca186324a14be78242f63b72bb68ee3e93319f7f5e65d9`
without reconstructing acceptance or invoking Resume. Both independent settled-diff
reviews approved the correction. Focused recovery/configuration tests pass
**178/178**. The canonical source gate discovered **431** Pester tests: **430**
passed, none failed, and one Windows-only launcher test was skipped on macOS; it
also parsed **19** PowerShell files and **2** JSON contracts and compiled all **25**
Bicep templates plus **5** parameter files. Direct Release tests remain
**1,304/1,304**: unit 479, Admin UI 155, local Setup 75,
observability/runtime 149, integration 92, end-to-end 106, architecture 115, and
security 133. The Release build has zero warnings and errors; `dotnet format
--verify-no-changes` and `git diff --check` pass.

Fresh generation `a365gw11-dev` used absent resource group
`rg-a365-custom-gw-phase6j`, ownership
`593edace-3230-4c77-b648-e8d6a163d965`, and ACR
`acra365gw11devlumzmj`, only in target subscription `internal-security-lab-02`
(`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`). Its accepted Plan
`sha256:82fc6bf0368ed1fd52b7d118d21848dce834c51f261363e187a3b2b90f101e86`
bound configuration
`sha256:a8ac824b365aa0243900b53df1cb3d453d1feaa5ab3e89bba4f17f52534dfc4d`
and source
`sha256:4428dc6da2b894b0e986938b35dc1f2786e1a4f805bf92b4c0c2306fda9d226a`;
authenticated What-If reported exactly eight `Create` predictions and zero other
changes, all in that target subscription. The run window was
`2026-08-30T00:26:07Z` through `2026-08-30T00:51:22Z` (09:26–09:51 KST).

Apply completed durable steps 1–6: Prerequisites, exact Azure authentication,
provider registration, foundation, Gateway API identity, and immutable images.
API, worker, and Admin UI ACR `QuickRun`s `de1`, `de2`, and `de3` all reached
`Succeeded` and were digest-checkpointed as respectively
`sha256:429177cfb745fe3cae122fae5e51d676699709faf0f6340097566aa10e67c274`,
`sha256:1f989a3f6945ef4470a39aa967262154feedb8e8b91422b2b8977849d3bc0dba`,
and
`sha256:f5a1c9786f05c041f59e5b1e8fbfcf411d024457bb78b440303c67736da03ead`.
Foundation deployment `a365gw-a365gw11-bootstrap-foundation-dev`, inert deployment
`a365gw-a365gw11-bootstrap-inert-dev`, and every observed nested deployment reached
`Succeeded`.

Bootstrap nevertheless failed closed during step 7's immediate strict readback.
For the fourteen Container App environment values produced from Bicep
`string(bool)`, ARM returned `True` or `False`, while the validator required
lowercase `true` or `false`; the first mismatch was
`Provisioning__ExecutionEnabled` (`False` deployed versus `false` expected). All
earlier provider-shape predicates passed. State therefore records steps 1–6
completed, step 7 `Failed`, and no step 8 or later state. No database
initialization, seed blueprint, workflow identity, Admin UI identity/credential,
runtime activation, registration, canary, Gateway key, Registry, Purview, or later
phase followed.

Independent GET-only provider-shape and recovery audits corroborated the bounded
diagnosis without deployment mutation. A second no-queue exact environment check
with the corrected validator passed both complete API/worker environment sets and
all **14/14** Boolean values. This read-only evidence does not authorize Resume:
correcting the validator changes the accepted source fingerprint. Preserve the
`a365gw11` state, accepted snapshot, deployed graph, identities, and images; never
reconstruct acceptance or Resume it under edited source.

Commit `a8d5a427f6728ff366a839f99aa9356aabd90254` centralizes the observed ARM
Boolean projection for inert recovery, immediate deployment validation, and final
Verify, while preserving ordinal name/value matching and the separate literal
lowercase `OutboxRelay__Enabled` contract. Both independent reviews approved the
settled correction. Focused tests pass **278/278**. The canonical source gate
discovered **433** Pester tests: **432** passed, none failed, and one Windows-only
launcher test was skipped on macOS; it parsed **19** PowerShell and **2** JSON files
and compiled all **25** Bicep templates plus **5** parameter files. Direct Release
tests remain **1,304/1,304**, the Release build has zero warnings/errors, and
format/diff checks pass. The next live action is a new isolated generation and
absent resource group only in the target subscription. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated; none of
its queues or messages were accessed. No target Service Bus message was read,
received, peeked, replayed, or settled.

Fresh generation `a365gw12-dev` then used absent resource group
`rg-a365-custom-gw-phase6k`, ownership
`0262fab5-5488-49be-bcb5-8ab4ccff83ab`, and ACR
`acra365gw12devzrlb27`, only in the same target subscription. Its accepted Plan
`sha256:1d38f7e591db817c9746d75c29f6ffa84ac484aa59249d595687a4efbe8cc2f8`
bound configuration
`sha256:ae68bb54439fa05f85d420b36f196086899f27ff78cae0d66fd0cf18d8b2a36d`
and source
`sha256:e7572f92d7bc1e0e2310936868beb39242e9061b0c095ebe37eb4938022f97dc`;
authenticated What-If reported exactly eight `Create` predictions and zero other
changes, all in the target subscription. The accepted Apply window was
`2026-08-30T01:22:42Z` through `2026-08-30T01:40:45Z` (10:22–10:40 KST).
An external JSON-lines renderer failed while the single bootstrap process remained
running; no second Apply or Resume was issued.

Apply completed durable steps 1–6. API, worker, and Admin UI ACR `QuickRun`s `de1`,
`de2`, and `de3` all reached `Succeeded` and were digest-checkpointed as
`sha256:a49cfd13ddb53fdc412f7564b79f1135dd3a15362d2ab2bd9d1f4f695b70a78f`,
`sha256:c132903c613bf2fc7d731a10bb88644821f2606bc2c69a1598bec9df640c966d`,
and
`sha256:40b3ebc0f6ed216a40eb50af47ba978720e87b843d9791ca8c377220be395277`.
Foundation deployment `a365gw-a365gw12-bootstrap-foundation-dev`, inert deployment
`a365gw-a365gw12-bootstrap-inert-dev`, and every observed nested deployment reached
`Succeeded`.

Step 7 nevertheless failed closed during its immediate strict readback. Bicep
derives `databaseAttestationDatabaseName` from the SQL module and exposes it as an
output; it is not a top-level deployment parameter. The validator correctly found
the empty inert output and evidence but also attempted to dereference the absent
optional parameter under `Set-StrictMode -Version Latest`, producing a masked
`PropertyNotFoundException`. Exact target-only GET proved the deployment remained
`Succeeded`, that the top-level parameter was absent, and that the output was
present. State records steps 1–6 completed, step 7 `Failed`, and no step 8 or later
record. No seed blueprint, workflow identity, SQL initialization, Admin UI
identity/credential, runtime activation, registration, canary, Gateway key,
Registry action, or later phase followed.

Three independent read-only reviews agreed that unchanged-source Resume would
GET-adopt the succeeded deployment and then deterministically fail the same
validator, while a corrected source cannot reuse the accepted fingerprint.
Preserve `a365gw12` state, snapshot, graph, identities, and images; never reconstruct
acceptance or Resume it. Commit
`15f5ee268f59fbc20de1b59734d5fd70d08e73b7` validates the five caller-supplied
database-attestation values across parameter, output, and evidence, while validating
the internally derived database name across output and evidence only. It still
requires empty inert and exact `GatewayDb` runtime values. The focused Experience
suite passes **73/73**. The canonical source gate discovered **449** Pester tests:
**448** passed, none failed, and one Windows-only launcher test was skipped on
macOS; it parsed **19** PowerShell files and **2** JSON contracts and compiled all
**25** Bicep templates plus **5** parameter files. Direct Release tests pass
**1,304/1,304** with the established per-project totals, the Release build has zero
warnings/errors, and format/diff checks pass. The next live generation is reserved
as `a365gw13` in absent resource group `rg-a365-custom-gw-phase6l`, only in target
subscription `6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated, and no
Service Bus message data plane was accessed in either subscription.

Fresh generation `a365gw13-dev` used absent resource group
`rg-a365-custom-gw-phase6l`, ownership
`123aedd4-c7c8-43ac-9be2-83e93c9b5dd1`, and ACR
`acra365gw13devgb7yh4`, again only in the target subscription. Its accepted Plan
`sha256:196d1b7de0bc02e9a9d4ff93471dd0696364fe5cf1d9c9998a57baa142f401e6`
bound configuration
`sha256:064fe82443341bf8f76c1a89be56e832ee2b3bc41d0748268f50f11fd75dd474`
and source
`sha256:5f154f039dfbd7814f49aa6024ebadfcc9d40bcf3e9713f1fc02ef61bcf943b8`.
Authenticated What-If again reported exactly eight `Create` predictions and zero
other changes. The accepted minimal profile was `dev`, Registry preview enabled,
exactly one reviewed manager application, Prompt Shields disabled, and Purview
disabled. The accepted Apply window was `2026-08-30T02:00:29Z` through
`2026-08-30T02:19:16Z` (11:00–11:19 KST).

Apply completed durable steps 1–6. API, worker, and Admin UI ACR `QuickRun`s
completed with respective digests
`sha256:830347df6d1018735a04d851e862c00514433bfdbd303a6119585883b2e582b2`,
`sha256:b8a4d8ff401992310f10f766ac31200c439d6d86ab509108984ccba72e26f527`,
and
`sha256:851e692413a0896e13485d4133b8f695a0b3680671ad1f0cc752aa6dcd915592`.
Foundation deployment `a365gw-a365gw13-bootstrap-foundation-dev`, inert deployment
`a365gw-a365gw13-bootstrap-inert-dev`, every nested deployment, and both Container
Apps reached `Succeeded`.

Step 7 failed closed because PowerShell pipeline assignment collapsed the inert
`else { @() }` result for `expectedManagerIds` to null. The sequence equality check
was null-tolerant, but the later strict `.Count` environment loop raised
`PropertyNotFoundException`. Exact target-only GET proved ARM carried an empty
array parameter, Bicep emitted zero manager-ID environment entries, both apps were
digest-pinned and secret-free, and the corrected database-name contract passed.
State records exactly steps 1–6 completed, step 7 `Failed`, no promoted outputs,
and no step 8 or later state. No seed blueprint or later mutation followed.
Message-count and SQL outbox evidence was not captured: SQL initialization never
started and no Service Bus message data plane was accessed. That absence is not a
zero-count claim.

Three independent read-only audits reproduced the exact exception and agreed that
same-source Resume would GET-adopt the succeeded deployment and fail the same
validator. A StrictMode GET-only run with only outer array capture corrected passed
the complete live a365gw13 validator. Preserve `a365gw13` state, snapshot, graph,
identities, and images; never reconstruct acceptance or Resume it. The bounded
source audit also found the identical singleton collapse in the later Admin UI
delegated-scope revalidator and final Verify. The Entra typed-array boundary and
join-only empty/singleton sites remain safe.

Commit `c92757080b1465ca0e140919038ba0176a5e0eb1` applies outer array capture to
exactly those three direct-`.Count` assignments, preserving manager-ID sequence
equality and exact one-grant/resource/`AllPrincipals`/`access_as_user` checks.
Independent review approved the correction and proved its AST regressions fail
against the pre-fix assignments. Focused Experience and Verification tests pass
**119/119**. The canonical source gate discovered **452** Pester tests: **451**
passed, none failed, and one Windows-only launcher test was skipped on macOS; it
parsed **19** PowerShell files and **2** JSON contracts and compiled all **25**
Bicep templates plus **5** parameter files. Direct Release tests pass
**1,304/1,304**, the Release build has zero warnings/errors, and format/diff checks
pass. The corrected deployment-affecting source fingerprint is
`sha256:f0d03d165f7a4c71664eba46ad8c33ad562968e124ea293ccea07e7217eb2307`.
The next live generation is reserved as `a365gw14` in absent resource group
`rg-a365-custom-gw-phase6m`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated, and no
Service Bus message data plane was accessed in either subscription.

Fresh generation `a365gw14-dev` used absent resource group
`rg-a365-custom-gw-phase6m`, ownership
`59b61c5f-7be5-44b2-a1a3-4d3819264cf2`, and ACR
`acra365gw14devwalxhk`, again only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Its accepted Plan
`sha256:4c2c1caf0e22795a52164c814bcc38c98611f708b8065f8b7ffa0297e1eae39c`
bound configuration
`sha256:8979733f0231e5bfad1e706410b60d377008e4bce244357afa80dc0252914335`
and source
`sha256:f0d03d165f7a4c71664eba46ad8c33ad562968e124ea293ccea07e7217eb2307`.
Authenticated What-If reported exactly eight `Create` predictions and zero other
changes. The accepted minimal profile remained `dev`, Registry preview enabled,
exactly one reviewed manager application, Prompt Shields disabled, and Purview
disabled. The single Apply was accepted at `2026-08-30T02:46:13Z` and stopped at
`2026-08-30T03:07:42Z` (11:46–12:07 KST); no duplicate Apply or Resume ran.

Steps 1–10 completed durably. Foundation deployment
`a365gw-a365gw14-bootstrap-foundation-dev`, inert deployment
`a365gw-a365gw14-bootstrap-inert-dev`, SQL private-endpoint deployment
`a365gw-a365gw14-bootstrap-sql-private-dev`, and all observed nested deployments
reached `Succeeded`. API, worker, and Admin UI images were checkpointed at
`sha256:777eadbeb87bec3518d3b84977b318d1b70bd3c7ec4990da5a310e82f9043db3`,
`sha256:bb1ea293692174900fc3d8144ee6bb9aaef0ad2a499b70b9ccfb69ac47802069`,
and
`sha256:fed1a0d17fde11e6a229e9e60fa33b68ffe2b4adef95fe62a8aa91ce1756028b`.
The source-bound, credential-free seed blueprint object/application ID is
`8e453b8d-8fe8-4a12-99a6-e083e753f597`; it retained exactly one reviewed manager
application. Workflow-v3 Entra configuration and the SQL private endpoint also
completed exact readback.

Step 11 failed within five seconds, before any step-11 database, firewall, or
SQL public-network mutation. In
`Get-ManagedIdentityClientId`, PowerShell parsed the interpolated Graph URL token
`$canonicalObjectId?` as the variable path `canonicalObjectId?`; StrictMode raised
`VariableIsUndefined` before `Invoke-AzJson` could run. A repository-wide AST audit
found exactly this one non-automatic question-mark variable path across all tracked
PowerShell. Target-only SQL control-plane readback proved public network access
remained `Disabled`, no bootstrap temporary firewall rule existed, and no database
evidence or recovery record was created. The corrected helper then completed both
exact live API/worker service-principal GETs. State records steps 1–10 `Completed`,
step 11 `Failed`, and no later step. No database initialization, Admin UI identity
or credential, runtime activation, registration, canary, Gateway key, or Registry
action followed. No SQL outbox or Service Bus message counts were captured; that
absence is not a zero-count claim, and no message data plane was accessed.

Same-source Resume would deterministically fail again, while the correction changes
the accepted source fingerprint. Preserve `a365gw14` state, accepted snapshot,
resource graph, identities, images, blueprint, and private endpoint; never
reconstruct acceptance or Resume it. Commit
`891121a6387e96f1f77eac26ef6b6cff94b79d54` braces the URL variable as
`${canonicalObjectId}` and adds both an exact executing URL regression and a
repository-wide AST guard that permits automatic
`$?` but rejects ambiguous non-automatic paths. Independent review approved the
settled correction. Focused database tests pass **5/5**. The canonical source gate
discovered **454** Pester tests: **453** passed, none failed, and one Windows-only
launcher test was skipped on macOS; it parsed **19** PowerShell files and **2** JSON
contracts and compiled all **25** Bicep templates plus **5** parameter files.
Direct Release tests pass **1,304/1,304** with the established per-project totals,
the Release build has zero warnings/errors, and format/diff checks pass. The
corrected deployment-affecting source fingerprint is
`sha256:c77ccf00013d106e440f30dda20928e65a165fd655a2eb9f88fdf17cd19a35e1`.
The next live generation is reserved as `a365gw15` in absent resource group
`rg-a365-custom-gw-phase6n`, only in the target subscription. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated, and no
Service Bus message data plane was accessed in either subscription.

Fresh generation `a365gw15-dev` then used absent resource group
`rg-a365-custom-gw-phase6n`, ownership
`abea5207-95b6-439b-ac3a-a1b2b3d7f2fb`, and ACR
`acra365gw15deve7kaui`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Its accepted Plan
`sha256:f03f5e9af7d91064959d1eaead74001d1584db55058cc902e9babdc51bd6b12b`
bound configuration
`sha256:f540e7b5d51beb8dccf23cb83093245ac00fb6bea231900771d1df0cb85d2688`
and source
`sha256:c77ccf00013d106e440f30dda20928e65a165fd655a2eb9f88fdf17cd19a35e1`.
Authenticated What-If reported exactly eight `Create` predictions and no other
change type. The accepted minimal profile remained `dev`, Registry beta explicitly
enabled, exactly one reviewed manager application, Prompt Shields disabled, and
Purview disabled. The single Apply ran from `2026-08-30T03:25:57Z` until
`2026-08-30T03:48:13Z` (12:25–12:48 KST); no Resume ran.

Steps 1–10 completed durably. The API, worker, and Admin UI image digests are
respectively
`sha256:ee760c926e2be32fe56243612b2315b1a7a3fb1f6034e56ddddcfbfac6c23881`,
`sha256:8be5395b46e4fc39070e6d405aaf7e847d5098ca26eae646cc4955477ae7b380`,
and
`sha256:30d0feb357c9f140c1ea83c35661eaab1021a164f6a47fdc7647812fc97c831c`.
The source-bound seed blueprint object/application ID is
`cd5432f4-03eb-4b66-bc5d-c9f943e75047`. Foundation, inert workload, seed
blueprint, workflow-v3 Entra, and SQL private-endpoint readbacks succeeded. Step 11
then failed before the database migrator child process, firewall, SQL public-network,
schema, or database evidence path began. The sanitized state intentionally retains
only the fixed step failure, so this checkpoint does not claim a narrower provider
root cause. No database initialization, Admin UI identity or credential, runtime
activation, registration, canary, Gateway key, or Registry action followed. No SQL
outbox or Service Bus message counts were captured; that absence is not a zero-count
claim, and no message data plane was accessed.

The same-source recovery Plan was
`sha256:cc615c5892406397d796701e014e88fc50e9584ef4abbca599a3b5054bac6710`
with the same configuration, source, and ownership. Its first read-only What-If
reported eight `Deploy` plus 29 `Ignore` predictions and correctly kept
`applyReady=false` because the old boundary covered only the inert graph. A later
read-only What-If reported eight `Deploy` plus 30 `Ignore` after Azure asynchronously
created the `Failure Anomalies - ai-a365gw15-dev` smart-detector rule under
`Microsoft.AlertsManagement`. Exact target-only ARM readback found that enabled Sev3/PT1M
`FailureAnomaliesDetector` scoped to the current Application Insights resource, but
untagged and bound to the default action group in retained generation
`rg-a365-custom-gw-phase6f`. That cross-generation binding is not owned recovery
evidence and was not adopted or mutated. Preserve `a365gw15` state, accepted source,
tenant objects, images, and ARM graph; edited source must never Resume it.

Commit `7cb433958fe6207ffb067cd4ce9c0340a8aa7df7` makes the recovery boundary
state-aware: it requires one contiguous, source-bound step prefix, independently
revalidates the completed SQL private endpoint and its generated NIC/DNS graph,
and accepts only the exact 26-resource inert plus four-resource SQL graph. It also
declares the Failure Anomalies rule with exact project/source/ownership tags,
Application Insights scope, and current project action group, and registers,
Doctor-checks, and Resume-revalidates `Microsoft.AlertsManagement`. Recovery remains
closed after any Admin UI deployment until that separate ARM footprint has an exact
reviewed boundary. Focused Experience/Azure tests pass **201/201**. The canonical
source gate discovered **469** Pester tests: **468** passed, none failed, and one
Windows-only launcher test was skipped on macOS; it parsed **19** PowerShell files
and **2** JSON contracts and compiled all **25** Bicep templates plus **5** parameter
files. Direct Release tests pass **1,304/1,304** with the established per-project
totals, the Release build has zero warnings/errors, and format/diff checks pass.
The corrected deployment-affecting source fingerprint is
`sha256:cd885109f65d749f2bcf4d52297c260b93ea733cf1d3e17e436bc4fade679972`.
The next live generation is reserved as `a365gw16` in absent resource group
`rg-a365-custom-gw-phase6o`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated, and no
Service Bus message data plane was accessed in either subscription.

Fresh generation `a365gw16-dev` then used absent resource group
`rg-a365-custom-gw-phase6o`, ownership
`f60ba56a-4a72-4cd7-88ec-0fd745461b90`, and ACR
`acra365gw16dev2vmejs`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Its accepted Plan
`sha256:eaa1970962c9c0f0121aa4793355c607e7a894e8719a816424daed5d85a5ff67`
bound configuration
`sha256:9ef66442b1a6989bf45bcaeeda47a6870122e6e9af7552d23a619203e31d9ce3`
and source
`sha256:cd885109f65d749f2bcf4d52297c260b93ea733cf1d3e17e436bc4fade679972`.
Authenticated What-If reported exactly eight `Create` predictions and no other
change type. The single Apply ran from `2026-08-30T04:29:11Z` through the failure at
`2026-08-30T04:50:04Z` (13:29–13:50 KST); no Resume ran.

Steps 1–10 completed durably. Exact ACR QuickRuns `de1`, `de2`, and `de3` all
succeeded. The API, worker, and Admin UI image digests are respectively
`sha256:f788ed6de78b463703e8f1cd42e29f7456c01786a04fc3b41499ef4bd42d68cd`,
`sha256:a9e9666638601fcb61812ab9e6e10e54042d7e794c5321dec8649cec0e952160`,
and
`sha256:73d7c03f7a018b8599af8070addf032981d2c9109ef570c0ccbe0ca7a85812c7`.
The source-bound seed blueprint object/application ID is
`cf919ca3-d180-4273-b730-cc9cc70471db`. The API managed-identity service principal
is object `324c541e-92ec-4eaa-89d3-05bca32f77d4`, client
`fdf9a655-7df0-4701-b4b1-d707ca9bff2f`; the workflow-v3 worker is object
`39f5af57-0d2f-4159-ac4e-5f50867883db`, client
`62b19841-63ff-4af0-a558-c6eae09da8ae`. Foundation, inert workload, seed
blueprint, workflow-v3 Entra, and SQL private-endpoint readbacks succeeded.

Step 11 failed before Azure SQL network, firewall, database migrator, schema, or
principal mutation. PowerShell parsed the comma-terminated Boolean expressions in
`tools/apply-migrations.ps1` as one GUID-valued array element despite all four
principal arguments being supplied, so the all-or-none guard failed closed.
Sanitized diagnostic
`.bootstrap/diagnostics/a365gw16-dev-20260830-045015.json` records the failure. No
database initialization, Admin UI credential, runtime activation, registration,
Registry action, Gateway key, or data-plane canary followed. No SQL outbox or
Service Bus counts were captured; that absence is not a zero-count claim, and no
Service Bus message data plane was accessed.

A later developer-only breakpoint diagnostic failed to stop before the corrected
script's SQL network boundary and initiated the authorized temporary public-network
enablement. It was immediately interrupted with `SIGINT` during the bounded
enabled-state wait, before firewall creation or the database-migrator call sites.
Target-only cleanup readback at `2026-08-30T05:03:49Z` (14:03 KST) proves the child
absent, SQL server `sql-a365gw16-dev` `Ready` with
`publicNetworkAccess=Disabled`, no `temp-a365gw-migration-*` firewall rule, and no
migration evidence or network-recovery file. Code order plus the absent firewall
proves no database child ran. This unintended diagnostic crossing and its cleanup
remain explicit evidence; the breakpoint method must not be reused.

Commit `61600ab86c721476d9b7b05121ce6a7d60e4e05a` uses typed independent Boolean
arrays, computes cardinality once, and tests the exact StrictMode binding fragment
and each partial-principal failure. The focused SQL-network gate passes **11/11**.
The canonical source gate discovered **470** Pester tests: **469** passed, none
failed, and one Windows-only launcher test was skipped on macOS; it parsed **19**
PowerShell files and **2** JSON contracts and compiled all **25** Bicep templates
plus **5** parameter files. Direct Release tests pass **1,304/1,304**, the Release
build has zero warnings/errors, and format/diff checks pass. The corrected
deployment-affecting source fingerprint is
`sha256:5b8184d3a05f364f98af05c78629a5772e7eafd690c479a11601e752b71e9b7d`.
Preserve `a365gw16`; edited source must never Resume it. The next live generation is
reserved as `a365gw17` in absent resource group `rg-a365-custom-gw-phase6p`, only in
target subscription `6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated, and no
Service Bus message data plane was accessed in either subscription.

Fresh generation `a365gw17-dev` then used absent resource group
`rg-a365-custom-gw-phase6p`, ownership
`da283279-50ec-489e-ae7f-8b2eff8c52a6`, ACR `acra365gw17dev3ws4cu`, accepted Plan
`sha256:d1a63ffc5a1c92266b6ae60b74f436bd6369229f8e709e95a534c3726fd90dca`,
configuration
`sha256:ca47cb9a2fec5f7aa5985d6b1570ef64251bdb23e65fe5195f0d8e12dd5db3ba`,
and source
`sha256:5b8184d3a05f364f98af05c78629a5772e7eafd690c479a11601e752b71e9b7d`,
only in target subscription `6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`.
Authenticated What-If reported exactly eight `Create` predictions and
`applyReady=true`. Its sole Apply ran from `2026-08-30T05:10:08Z` through
`2026-08-30T05:35:04Z` (14:10–14:35 KST); no Resume ran.

Steps 1–10 completed durably. Exact ACR QuickRuns `de1`, `de2`, and `de3` produced
API, worker, and Admin UI digests
`sha256:4937e1c0eed1e2c09b26629dad6405632cc83c44e0ba9145a5a6971ee609cd03`,
`sha256:fbd964a4157149021b29a28db04233f6e6ee5f49720d3efa212ba282b7fbe66e`,
and
`sha256:2e0024b8c1f669796a3259dcfee3f6870adf27142cd99eb881a8b21767445671`.
The source-bound seed blueprint object/application ID is
`fd5109e3-1a82-4d0a-bac0-0bae894a12f1`; inert API and worker principal object IDs
are `20d1dc43-132b-4314-8131-e80b41ce353f` and
`b7b3edbb-5969-47bb-973a-9614285a2c01`. Foundation, inert workload, seed blueprint,
workflow-v3 Entra, and SQL private-endpoint readbacks succeeded.

Step 11 issued the reviewed temporary SQL public-network enable request, but its
bounded poll never observed `Enabled` and failed before firewall creation or the
database-migrator child. Activity Log records one successful SQL server write at
`2026-08-30T05:31:49Z`, correlation
`90c2533b-f6ea-4ffd-b4ec-087fd6a59ce2`, and no firewall-rule write. Cleanup readback
proves `sql-a365gw17-dev` `Ready` with `publicNetworkAccess=Disabled`, no temporary
firewall rule, network-recovery file, or migration evidence. Sanitized diagnostic
`.bootstrap/diagnostics/a365gw17-dev-20260830-053545.json` retains the safe failure.
No database initialization, Admin UI credential, activation, registration,
Registry action, Gateway key, or canary followed; no message data plane was
accessed.

Same-source recovery What-If returned exactly eight `Deploy` plus 31 `Ignore` and
failed closed against the reviewed 30-resource boundary. The extra resource was the
Defender-for-Storage-managed Event Grid system topic
`sta365gw17dev3ws4cu-d3d27d40-91b3-4258-baf8-e3ca0856271a`, uniquely source-bound
to the generation's storage account and carrying one Succeeded, reverse-bound
`StorageAntimalwareSubscription` child. Microsoft documentation confirms the
required same-resource-group system topic; its exact generated topic/child names,
BlockBlob filter, and retry fields remain bounded live-generation evidence, not a
portable provider guarantee.

Commit `bee437fe1e2a19976565777184f70f2bbf1319ec` adds the exact
`Microsoft.EventGrid` provider/subscription boundary and a separately fingerprinted
typed absent/present recovery extension. Provider inventory and What-If must match,
destination URLs are never projected, and only exact 26/27/30/31 graphs are
accepted. Independent security review found no remaining actionable issue. Focused
Experience/Azure/Common tests pass **106/106**, **116/116**, and **67/67**. The
canonical source gate discovered **491** Pester tests: **490** passed, none failed,
and one Windows-only launcher test was skipped on macOS; it parsed **19** PowerShell
files and **2** JSON contracts and compiled all **25** Bicep templates plus **5**
parameter files. Direct Release tests pass **1,304/1,304**, the Release build has
zero warnings/errors, and format/diff checks pass. Corrected deployment-affecting
source is
`sha256:6cf2268084bc3dbadb692701988a900ea4b7e159bafb9a7a521cde4cfa76241b`.
Preserve `a365gw17`; edited source must never Resume it. The next live generation is
reserved as `a365gw18` in absent resource group `rg-a365-custom-gw-phase6q`, only in
target subscription `6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated.

The isolated `a365gw18` generation then accepted Plan
`sha256:d5903ae8cbb0ad77ac088ef43563e904e0bc3342017df3da773f471ac3503cd0`
for resource group `rg-a365-custom-gw-phase6q`, deployment ownership
`b4934ae4-98d3-4126-a69d-0dbdd61a7fff`, configuration
`sha256:90a5a59edaf1cf69cabb46b82262e095d73b41a78526a71b62162daa2ee9abdb`,
and source
`sha256:6cf2268084bc3dbadb692701988a900ea4b7e159bafb9a7a521cde4cfa76241b`.
One Apply completed steps 1–10 and failed safely at step 11. Exact target-only
readback proved the tenant management-group policy `AzureSQL_PublicNetwork_Modify`
under assignment `MCAPSGovDeployPolicies`, with no applicable exemption, keeps the
SQL public endpoint `Disabled`. No firewall rule, migrator, schema, database
evidence, Admin credential, runtime activation, registration, Registry action,
Gateway key, canary, or Service Bus message-data-plane access followed. Preserve
`a365gw18`; its frozen source must never be resumed after the database-path edit.

The replacement candidate uses a digest-pinned, VNet-private manual Container Apps
Job, not a SQL public-network exception. It persists a safe execution-intent receipt,
authorizes exactly one retry-disabled execution, temporarily assigns only the Job
identity as the singular SQL Entra administrator, restores the exact original
administrator after the execution settles, validates exactly three evidence records
from the exact Log Analytics stream, and verifies zero SQL firewall rules plus zero
Azure RBAC/Graph application roles on the Job identity. Independent read-only
review found no remaining correctness or safety blocker. This is local source/test
evidence only; it has not changed Azure. The next live generation is reserved as
`a365gw19` in absent resource group `rg-a365-custom-gw-phase6r`, only in target
subscription `6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` remains outside the proof.
+
The frozen local candidate gate is a zero-warning/zero-error Release build and
**1,324/1,324** direct Release tests: unit 495, Admin UI 155, local Setup 75,
observability/runtime 149, integration 92, end-to-end 106, architecture 119, and
security 133. The canonical bootstrap/runtime gate discovers **509** Pester tests:
**508** pass, none fail, and one Windows-only launcher test is skipped on macOS. It
parses **19** PowerShell files and **2** JSON contracts and compiles all **26** Bicep
templates plus **5** parameter files. `dotnet format --verify-no-changes`, `git diff
--check`, and all **58** repository-local links across **55** Markdown files pass.
Independent review also passes 324 changed-bootstrap Pester tests, 55 targeted
migrator/recovery unit tests, and four database-Job architecture tests. These are
source-only results, not deployment evidence.


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
   substitute the old partial `tools/bootstrap.ps1`. Preserve `a365gw6` and
   `a365gw7` at 6/19, `a365gw8` at 3/19, `a365gw9` at 6/19, and `a365gw10` at
   6/19. Preserve `a365gw11`, `a365gw12`, and `a365gw13` with steps 1–6 complete
   and step 7 `Failed` after each inert deployment succeeded. Preserve `a365gw14`,
   `a365gw15`, `a365gw16`, `a365gw17`, and `a365gw18` with steps 1–10 complete and
   step 11 `Failed` before database migration. In
   order, those generations preserve exact
   image-build recovery; the terminal inert-deployment/private-ACR first-pull
   failure; a succeeded
   dedicated-pull foundation stopped by incomplete typed ACR policy readback; a
   completed foundation/API/images prefix stopped by the stale scope/audience
   guard; and a succeeded inert graph whose recovery What-If exposed the unhandled
   `Ignore` contract. `a365gw11` preserves a succeeded inert graph whose immediate
   validator rejected ARM Boolean casing; `a365gw12` preserves the next succeeded
   inert graph whose validator dereferenced a Bicep-derived, output-only database
   name as though it were a top-level ARM parameter; and `a365gw13` preserves the
   next succeeded inert graph whose validator collapsed its empty expected-manager
   array to null before a strict `.Count`. None of those three reached step 8.
   `a365gw14` then crossed that boundary, created its source-bound seed blueprint,
   configured workflow-v3 Entra, and completed the SQL private endpoint before the
   ambiguous Graph URL variable stopped step 11. `a365gw15` repeated that complete
   prefix before failing prior to database mutation; its later read-only recovery
   What-If exposed an asynchronously created, cross-generation Failure Anomalies
   action-group binding and the need for the exact 26+4 state-aware graph.
   `a365gw16` repeated the exact prefix and exposed comma-parsed Boolean principal
   binding at the step-11 all-or-none guard. A later diagnostic briefly initiated
   its authorized temporary SQL public-network boundary but was interrupted before
   firewall creation or the migrator; cleanup proved the server Disabled with no
   temporary rule, recovery file, or database child. None may consume edited source
   or a later recovery Plan. `a365gw17` repeated the exact prefix; its reviewed SQL
   public-network request never became observable to the bounded poll, and cleanup
   again proved Disabled with no firewall or migrator. Its same-source recovery
   What-If then exposed the asynchronously created Defender Storage Event Grid
   system topic as the sole 31st Ignore resource.
   `a365gw18` repeated the exact prefix and proved the tenant management-group policy
   keeps SQL public access `Disabled`, so the incompatible public migration path
   stopped safely. Preserve that generation; never Resume it with the private-Job
   correction.
   Commit `bb001483bae0577d7c29a9638c1c7275dae44525` implements and independently
   reviews the bounded, state-aware `Ignore` rule; its GET-only `a365gw10` smoke is
   recovery evidence, not authorization to Resume that frozen source generation.
   Commit `15f5ee268f59fbc20de1b59734d5fd70d08e73b7` implements and independently
   reviews the derived database-name readback correction. Commit
   `c92757080b1465ca0e140919038ba0176a5e0eb1` implements and independently
   reviews the strict array-cardinality correction. Commit
   `891121a6387e96f1f77eac26ef6b6cff94b79d54` implements and independently reviews
   the Graph URL interpolation correction and its repository-wide AST guard. The
   state-aware recovery and owned smart-detector correction is commit
   `7cb433958fe6207ffb067cd4ce9c0340a8aa7df7`. Commit
   `61600ab86c721476d9b7b05121ce6a7d60e4e05a` implements and regression-tests the
   principal/bootstrap Boolean-array correction. Commit
   `bee437fe1e2a19976565777184f70f2bbf1319ec` implements the exact typed Defender
   Storage system-topic recovery boundary. The next live generation is reserved as
   `a365gw19` in absent resource group `rg-a365-custom-gw-phase6r`, only
   in target subscription
   `6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Until one disposable run completes
   Apply/Verify,
   distinguish locally validated corrected source and partial live recovery proof
   from a completed bootstrap. If a completed resource group was
   deleted, preserve state and use a separately reviewed disaster-recovery decision;
   bootstrap intentionally refuses automatic tenant-object/credential replay.
7. After every verified change, update this file and the deployment checkpoint with
   exact tests, digests, revisions, schema/recovery state, all queue/outbox counts,
   safe external identifiers, and the next action. Never record secret material.
