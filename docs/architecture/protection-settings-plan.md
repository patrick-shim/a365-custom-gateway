# Protection capability and Gateway Settings plan

Status: database recovery independently verified; inert API startup correction passed offline acceptance.

Last updated: 2026-09-06 (Asia/Seoul).

This document records the implemented capability-only bootstrap and role-aware
Gateway Settings architecture. Database recovery passed independent readback, but
visible Resume stopped at API readiness: inert deployment enabled Prompt Shields
before capability attestation. The source correction delays runtime activation
while retaining selected infrastructure. Correction-specific clean-export acceptance and independent source review passed;
exact-commit hosted CI remains required before deployment.
No supported existing command admits that new source into completed pinned recovery.
The deployment is preserved; any new isolated target requires separate authority.
Admin UI, registration, observability, and protection E2E remain unproved.

## Decision and boundaries

Bootstrap installs a deployment's capabilities. The deployed Gateway owns ongoing
configuration, confirmation, reconciliation, readiness, and registration use.

| Capability | Bootstrap owns | Gateway Settings owns |
|---|---|---|
| Agent 365 registration beta | Deployment-wide admission capability and required Entra configuration. **Quick development** defaults this capability on only with an explicit beta acknowledgement. Staging and production remain closed. | Displays capability state. It does not turn the deployment-wide beta boundary on. A signed-in Administrator still completes each registration's user-only Registry action. |
| Prompt Shields | Azure AI Content Safety resource, managed-identity RBAC, endpoint wiring, and capability readback. | Deployment default, per-registration enablement, readiness display, and ongoing changes. |
| Microsoft Purview | API and automation identities, narrow Graph and compliance RBAC, certificate and Key Vault path, runtime wiring, and capability readback. | Tenant authority connection, SIT inventory and selection, Know Your Data creation/readback, blueprint-specific DLP profiles and rules, propagation/readiness, defaults, per-registration enablement, and ongoing changes. |

Ordinary bootstrap does not select a sensitive information type or author, update,
or delete a Purview policy. It never treats provider configuration, platform
`Running`, or local tests as live-readiness proof.

The Purview scope contracts stay independent:

- Know Your Data uses the fixed tenant-wide enterprise-AI-apps location
  `ee1680d0-702f-4090-b26c-c49091e86531` as `Group`.
- DLP uses exactly one selected reusable blueprint application ID per profile as
  `Individual`.
- Both use the `Application` enforcement plane.
- A blueprint ID is never inserted into the Know Your Data Group, even when the
  values happen to compare equal to another identifier.

## Implemented source state

- Guided Setup provides **Full evaluation**, **Core Gateway**, and **Custom**
  capability presets. Quick development defaults to Full evaluation; staging and
  production keep Registry beta closed.
- Bootstrap configures Agent 365 beta admission, Prompt Shields infrastructure, and
  Purview prerequisites with separate acknowledgements. It does not inventory SITs
  or call policy-authoring cmdlets.
- `/settings` implements role-aware capability cards, tenant connection and
  companion handoff, expiring SIT inventory, independent KYD and blueprint DLP
  review/confirmation, persisted operation progress, readiness, and registration
  defaults.
- The API implements additive `/api/v1/protection` routes with exact delegated
  actor checks, review and confirmation values, ETag/row-version concurrency,
  canonical idempotency, rate limiting, and RFC 9457 failures.
- SQL persists capability, connection, SIT generation/item, KYD, one-profile-per-
  blueprint DLP, legacy review candidate, operation, and eight-step operation state.
- Protection work routes through `gateway-protection-admin-v1`, independently of
  registration workflow v3 and `gateway-provisioning-v3`.
- Purview is effectively enabled only for the exact resolved blueprint and Ready,
  unexpired DLP profile. Prompt Shields requires exact installed capability
  readback. Stored requested settings do not override effective readiness.
- Beta.2 has reached the database stage in the authorized replacement attempt.
  Existing complete live evidence belongs to an older revision and does not prove
  this implementation. Only the bounded database recovery correction has
  completed live verification; remaining deployment and E2E gates are unfinished.

## Implemented architecture

### Capability plane

`bootstrap/bootstrap.ps1` remains the canonical resumable deployment engine. A
fresh deployment records immutable, non-secret capability facts:

- whether Agent 365 beta admission was installed and may open for this environment;
- the Content Safety resource and API managed-identity role readback;
- the Purview runtime and automation identities, exact app-role/RBAC assignments,
  certificate metadata, Key Vault reference, and workload wiring; and
- whether each capability is `Installed`, `Unavailable`, or
  `PendingPropagation`.

Capability readback does not create a protection profile and does not mark a
provider data plane Ready. Bootstrap Verify proves only what it read. It must not
convert policy absence into a deployment failure.

### Setup presets and defaults

Setup uses a plain-language
**Capabilities to install** choice:

1. **Full evaluation (recommended for Quick development).** Selected by default.
   Agent 365 registration beta, Prompt Shields infrastructure, and Purview
   prerequisites are all checked. The user must still acknowledge the unsupported
   production status of Registry beta and review Prompt Shields quota/cost and
   Purview tenant-role requirements before Plan.
2. **Core Gateway.** Installs the Gateway and development registration capability
   but no optional Prompt Shields or Purview dependencies.
3. **Custom.** Lets the user independently include or exclude Prompt Shields and
   Purview prerequisites.

Checked means **install or prepare this shared capability**. It never means that
every agent is protected, that a Purview policy has been authored, or that runtime
enforcement is Ready. Prompt Shields and Purview cards name the resource, possible
cost/quota, required administrator handoff, and the post-deployment Settings action.

Staging and production never enable Agent 365 Registry beta. Their presets remain
production-safe even if a user previously selected Full evaluation in development.
No remembered browser choice can weaken that environment boundary.

### Governance plane

The authenticated Gateway control plane is the sole source of protection
configuration:

1. **Tenant connection.** An Administrator starts a bounded Purview connection
   operation for the exact tenant. Where Security & Compliance PowerShell requires
   an interactive Windows session, Settings presents a Gateway-provided Windows
   companion command. The companion is only an execution bridge: Settings owns the
   operation and choices. The companion uses official sign-in, sends no token or
   provider body to the Gateway, and returns only bounded typed identity,
   authorization, inventory, and readback facts.
2. **SIT inventory.** The connected session calls
   `Get-DlpSensitiveInformationType`. Settings shows the exact bounded tenant
   inventory and requires an explicit no-default selection keyed by GUID while
   preserving the exact Unicode name and publisher. No static catalog, free-text
   value, Graph sensitivity-label substitute, or ordinary-bootstrap selection is
   allowed.
3. **Know Your Data.** The Administrator separately reviews and confirms the one
   tenant-wide Group operation. Exact readback records configuration state, not
   propagation or runtime readiness.
4. **Blueprint DLP.** The Administrator chooses one resolved reusable blueprint
   and creates or updates one Individual-scoped DLP profile/rule for that blueprint.
   Policy mode, activities, actions, and SIT selection are shown before a separate
   explicit confirmation.
5. **Readiness.** The Gateway re-reads exact policy state, safely attests the API
   managed-identity token roles in memory, waits for propagation when needed, and
   requires a bounded data-plane allow/block result before reporting the profile
   `Ready`.
6. **Use.** Settings controls deployment defaults. Registration and agent detail
   surfaces control per-registration Prompt Shields and Purview use. Purview can be
   enabled only when the registration's exact blueprint has a Ready DLP profile.

New-blueprint registration is no longer a hidden policy-authoring path. It first
completes the core identity lifecycle. An Administrator then configures that
resolved blueprint in Settings and enables Purview for the registration after the
profile is Ready. Optional protection unavailability never closes the core
registration path.

### Roles

- `Gateway.Administrator`: read capabilities and governance state; start
  interactive connection; select SITs; confirm create/update/reconcile operations;
  change defaults; and enable protections on registrations.
- `Gateway.Operator`: read status and safe operation progress only. It cannot
  connect tenant authority, select a SIT, mutate policy, or change defaults.
- `Gateway.Auditor` and `Gateway.SupportReader`: read bounded status appropriate to
  their existing role; no mutation and no provider internals.

Every API route rechecks role, tenant, user object ID, delegated scope, operation
state, and target. UI visibility is not authorization.

## Admin Settings experience

`/settings` includes a **Protection capabilities** area with three independent cards:

- Agent 365 beta: environment, installed/open/closed state, acknowledgement
  provenance, and immutable deployment-wide explanation.
- Prompt Shields: Content Safety/RBAC capability, default for new registrations,
  and a link to per-agent controls.
- Microsoft Purview: prerequisites, tenant connection, KYD, blueprint profiles,
  propagation, token roles, and runtime-verdict readiness as separate states.

The Purview journey is progressive and fail-closed:

1. inspect bootstrap-prepared prerequisites;
2. start or refresh tenant connection;
3. on Windows, complete the interactive provider sign-in;
4. load the current tenant SIT inventory;
5. explicitly select and confirm a SIT;
6. separately review and confirm tenant-wide KYD;
7. select one blueprint and review and confirm its Individual DLP profile/rule;
8. monitor persisted operation stages and exact readback;
9. perform the approved synthetic allow/block readiness check; and
10. only then enable a default or registration.

Each confirmation names the tenant, operation, scope type, blueprint when
applicable, SIT GUID and exact name, mode, activities, and actions. It states that
readback is not propagation or verdict proof. Destructive replacement, scope
broadening, policy deletion, certificate rotation, and cleanup are not implicit
save actions.

Unavailable, not connected, awaiting administrator, pending propagation,
verification failed, and Ready are visually and semantically distinct. A stale
inventory cannot be selected. Refresh never silently changes a stored choice.

## API surfaces

The implemented `/api/v1` control-plane surfaces are:

| Surface | Purpose |
|---|---|
| `GET /system/config` and `PATCH /system/config` | Continue to expose and update safe registration defaults, but reject a Purview default unless its dependency rules are satisfiable. |
| `GET /protection/capabilities` | Read bootstrap-installed capability facts separately from provider readiness. |
| `GET /protection/purview/connection` | Read bounded tenant connection and authorization state. |
| `POST /protection/purview/connection-operations:review` | Review a short-lived, exact-tenant connection operation without mutation. |
| `POST /protection/operation-reviews:confirm` | Exchange a one-time review value for a one-time confirmation value. |
| `POST /protection/purview/connection-operations` | Start the confirmed interactive connection operation. |
| `POST /protection/purview/connection-operations/{id}:review-completion` | Review bounded companion evidence before submission. |
| `POST /protection/purview/connection-operations/{id}:complete` | Accept only typed, bounded companion evidence after rechecking the signed-in Administrator and operation binding. |
| `GET /protection/purview/sensitive-information-types` | Read the current bounded inventory for the active connection; never expose provider bodies. |
| `GET /protection/purview/know-your-data` | Read independent tenant-wide KYD configuration and readiness. |
| `POST /protection/purview/know-your-data-operations:review` | Review create/update/readback for the fixed Group. |
| `POST /protection/purview/know-your-data-operations` | Start the separately confirmed fixed-Group operation. |
| `GET /protection/purview/dlp-profiles` | List all authorized profiles and states, not only Ready rows. |
| `POST /protection/purview/dlp-profile-operations:review` | Review a profile mutation for exactly one blueprint Individual scope. |
| `POST /protection/purview/dlp-profile-operations` | Start the separately confirmed blueprint profile operation. |
| `POST /protection/purview/dlp-profiles/{id}:review-reconcile` | Review exact provider reconciliation. |
| `POST /protection/purview/dlp-profiles/{id}:reconcile` | Re-read exact provider state without silently rewriting it. |
| `POST /protection/purview/dlp-profiles/{id}:review-runtime-validation` | Review the bounded synthetic runtime readiness check. |
| `POST /protection/purview/dlp-profiles/{id}:validate-runtime` | Start a bounded, explicitly approved synthetic readiness check. |
| `GET /protection/operations/{id}` | Read durable stages, safe timestamps, status, correlation ID, blockers, and next action. |

All mutation routes require `Gateway.Administrator`, a canonical UUIDv4
`Idempotency-Key`, optimistic concurrency, and an explicit reviewed-confirmation
token bound to the same user, tenant, target, payload hash, and expiry. Review
responses authorize no mutation by themselves. Problem responses remain RFC 9457
and contain only safe codes and correlations.

Existing registration contracts remain additive. `promptShieldEnabled`,
`purviewEnabled`, and `purviewMode` stay compatible; the API adds effective
capability/profile readiness and rejects Purview enablement unless the
registration's resolved blueprint has the exact Ready profile.

## Persistence and orchestration

The source replaces the combined profile assumption with explicit records:

- `ProtectionCapability`: bootstrap-owned deployment capability and last exact
  readback, without secret material.
- `PurviewTenantConnection`: tenant, status, bounded authority metadata,
  inventory generation, expiry, and last verification.
- `PurviewSensitiveInformationTypeSnapshot`: generation, canonical GUID, exact
  name, publisher, and retrieval time; snapshots expire and are never policy
  authority by themselves.
- `PurviewKnowYourDataConfiguration`: the fixed Group, desired configuration,
  provider identifiers after readback, status, and row version.
- `PurviewDlpProfile`: exactly one blueprint application ID, SIT GUID/name,
  mode, activities/actions, provider identifiers after readback, propagation and
  runtime readiness, and row version.
- `ProtectionAdminOperation` and ordered steps: reviewed intent, payload hash,
  actor, target, idempotency key, status, safe failure code, timestamps, and
  readback references.

Provider work is asynchronous through the transactional outbox and
`gateway-protection-admin-v1`. Its eight persisted v1 stages are Validate Reviewed
Intent, Discover Provider State, Apply Reviewed Mutation, Record Exact Readback,
Verify Propagation, Attest Token Roles, Validate Runtime Verdict, and Complete. It
does not reuse or alter the seven registration stages or
`gateway-provisioning-v3`. Every external mutation persists intent first, discovers
exact provider state, performs at most the reviewed mutation, records exact typed
readback, and is safe after duplicate delivery.

The prepared certificate is resolved from Key Vault only inside the approved
worker path. Certificate bytes, passwords, tokens, prompts, responses,
authorization headers, and provider bodies never enter SQL, queue payloads,
Problem Details, browser state, or logs.

## Migration and compatibility

1. Preserve all existing Azure, Entra, Key Vault, policy, SQL, and ignored
   `.bootstrap/` evidence. No migration deletes or recreates provider objects.
2. A deployment already started under old bootstrap source resumes only with that
   exact source and state. New source never adopts or rewrites its accepted Plan.
3. Fresh configuration no longer collects SIT and policy-authoring fields.
   Compatibility parsing identifies legacy fields without silently authoring
   policy and reports the post-deployment Settings action.
4. The ordered migration copies existing combined `PurviewPolicyProfiles` into
   review-required KYD and per-blueprint legacy candidates.
   Split multi-blueprint arrays into one candidate per blueprint. Keep provider IDs
   as evidence, mark every candidate non-Ready, and require exact independent
   readback before use.
5. Preserve existing registration feature values, but compute effective readiness
   independently. A registration whose Purview profile is absent, stale, or
   unverified fails closed for protected requests without closing ordinary
   unprotected registration.
6. Preserve Prompt Shields defaults and per-registration values when the Content
   Safety capability still reads back exactly. Otherwise report unavailable and
   fail protected requests closed.
7. Keep staging and production Agent 365 registration closed. A legacy development
   enablement remains explicit evidence; the new Quick development default requires
   the new beta acknowledgement and cannot be inferred from an old boolean.
8. API additions preserve current fields. The old combined profile surface remains
   compatibility-only while Settings-owned operations use the new records.

Because the repository currently has no in-place application upgrade path, live
validation uses a clean deployment. The implemented compatibility rules do not
authorize an ad hoc upgrade.

## Recovery and security

- Preserve the last accepted intent and provider identifiers on timeout or unknown
  outcome. Recovery is readback-first and never repeats a create blindly.
- A restarted browser reloads durable operation state but does not recover or reuse
  an interactive sign-in, review token, or confirmation. The Administrator must
  reconnect or reconfirm as directed.
- A changed inventory generation, SIT name, tenant, blueprint, mode, activity,
  action, capability readback, or row version invalidates pending confirmation.
- A removed or renamed SIT returns the affected profile to review-required; it is
  never substituted.
- Policy readback, Azure resource existence, role assignment, and platform
  `Running` remain separate facts. Only token-role attestation plus the bounded
  data-plane result can make runtime readiness Ready.
- Unknown provider outcomes, malformed inventories, duplicate objects, ambiguous
  scope, offline-versus-inline mismatch, or stale authority fail closed.
- `downloadText` may be offline. The Gateway never claims response-side blocking
  from that result.
- Cleanup, policy deletion, scope replacement, identity deletion, and certificate
  rotation remain separately authorized runbook operations.

## Test plan

### Contract and unit tests

- environment matrix for Agent 365 beta: Quick development default-on only after
  acknowledgement; staging and production closed;
- bootstrap schemas and UI contain capability inputs but no SIT or policy-authoring
  choice;
- capability readback is independent of KYD, DLP, propagation, and runtime readiness;
- role/tenant/scope checks and explicit-confirmation expiry on every mutation;
- SIT GUID/exact-name pairing, Unicode handling, bounded inventory, stale generation,
  rename, removal, duplicate, malformed, and unauthorized cases;
- fixed KYD Group versus one-blueprint Individual DLP invariants;
- idempotency, optimistic concurrency, duplicate delivery, timeout, unknown outcome,
  readback-first recovery, and no blind replay;
- migration of zero, one, and multi-blueprint legacy profiles to non-Ready
  candidates without provider mutation;
- registration defaults and per-agent settings, including unavailable and
  not-Ready fail-closed behavior;
- no secret or content material in contracts, persistence, queues, logs, errors, or
  browser state.

### Integration and UI tests

- API and SQL migrations, outbox dispatch, dedicated queue isolation, worker
  redelivery, and exact provider-adapter fixtures;
- Administrator mutation versus Operator, Auditor, SupportReader, wrong-tenant,
  app-only, and missing-scope denial;
- desktop and narrow-width Settings journeys for every empty, pending, blocked,
  failed, stale, and Ready state;
- Windows companion cancellation, wrong account, guest account, tenant mismatch,
  unavailable cmdlet, restart, timeout, and successful bounded handoff;
- registration against a new blueprint remains possible before optional protection;
  later profile readiness enables Purview without rerunning core provisioning;
- existing Prompt Shields behavior and receipt binding remain unchanged.

Automated tests never mutate a live tenant. Offline provider fixtures, policy
readback, and a platform `Running` state are not live evidence.

## Phases and acceptance gates

### Phase 0 — documentation and contract approval

**Complete.**

- The ownership boundary, OpenAPI design, persistence migration, queue version,
  companion trust boundary, and fail-closed readiness contract were approved.

### Phase 1 — bootstrap capability-only path

**Complete in source.**

- Guided and terminal bootstrap no longer request a SIT or author policy.
- Quick development defaults to **Full evaluation**, with Agent 365 beta, Prompt
  Shields infrastructure, and Purview prerequisites checked. It cannot continue
  without the explicit beta and cost/authority review; staging and production
  cannot enable Registry beta.
- Core Gateway and Custom presets remain available and explain exactly what will
  and will not be installed.
- Prompt Shields and Purview prerequisites have exact capability readback.
- Existing accepted deployments remain source/state bound and recoverable.

### Phase 2 — Settings control plane

**Complete in source.**

- Role-aware capability, connection, inventory, KYD, profile, operation, default,
  and per-registration experiences are implemented.
- API authorization, persistence, idempotency, confirmation, audit, and recovery
  contracts pass focused and integration tests.
- KYD and DLP scopes cannot be merged.

### Phase 3 — provider orchestration and readiness

**Complete in source.**

- Interactive Windows connection and noninteractive certificate-backed operations
  use only the prepared authority.
- Exact readback, token-role attestation, propagation, and runtime result remain
  distinct.
- Profiles become Ready only after their exact independent evidence passes.

### Phase 4 — offline release candidate

**Offline acceptance passed.**

| Gate | Final result |
|---|---:|
| Release build | 0 warnings, 0 errors |
| Gateway.UnitTests | 805 passed |
| Gateway.AdminUi.Tests | 217 passed |
| Gateway.Setup.Tests | 255 passed |
| Gateway.ObservabilityRuntime.Tests | 232 passed |
| Gateway.ArchitectureTests | 131 passed |
| Gateway.IntegrationTests | 107 passed |
| Gateway.EndToEndTests | 116 passed |
| Gateway.SecurityTests | 141 passed |
| **.NET total** | **2,004 passed, 0 failed** |
| Pester | 846 passed, 0 failed, 7 skipped |
| Format | All nine targets passed |
| Independent security and UI source review | Passed; no remaining actionable findings |
| Clean export | Release, all eight test projects, canonical bootstrap gate, layout and launcher smoke passed |

Canonical source gate: 20 PowerShell files and 2 JSON files, with 28 Bicep templates and 3 parameter files compiled, with Pester behavior tests.


Hosted validation exposed Windows-only fixture paths and platform differences
in passwordless PKCS12 verification. The tests now use a native temporary path and
accept both documented null and empty password encodings independently for the
MAC, safe contents, and private key. All eight synthetic encoding combinations
pass; nonempty-password and public-only packages are rejected. The actual export
must retain the exact certificate and prove its matching private key by an
in-memory signature. Both affected files passed again (11 tests, zero
failures/skips) in the canonical checkout and clean export; fresh independent
review of the encoding correction passed. Production source, test counts, and UI
contracts are unchanged, so the earlier full integrated results above remain
applicable alongside this incremental evidence. The preceding hosted run passed
.NET, Bicep, Ubuntu, and macOS; the Windows proof correction still requires
exact-commit hosted acceptance at this handoff. All five hosted jobs must pass
before source closure.

The fresh independent review passed the combined source after explicitly
rechecking all four original findings: shared API/worker runtime identity and
token subject, exact capability/runtime binding, cancellation-owned process
termination, and provider-ID-bound KYD/DLP updates with exact readback and
ambiguous-outcome recovery. It also rechecked the exact 19-key
`BootstrapCapabilities` startup materialization and subsequent integration
corrections to bootstrap identity attestation, API credential guards, current
tenant/SIT readiness, and Settings action compatibility. No earlier review was
reused as acceptance.

UI acceptance uses the full bUnit suite and fresh independent source review.
The user explicitly accepted that evidence after automatic browser policy blocked
local inspection. Desktop and narrow-width browser inspection was waived, not
reported as executed. AgentDetails distinguishes effective protection from
selected-profile readiness. Settings uses the supported UploadText Block rule
for both policy modes, and only Enforce can request runtime allow/block proof.


Bootstrap emits and independently reads back exactly 19 `BootstrapCapabilities`
environment keys. Inert startup has Enabled=false and blank facts. Runtime carries
an ownership/source/time-bound snapshot that API startup strictly validates and
materializes through a SQL application-locked, transactional, deterministic,
restart-idempotent upsert. Drift and partial state fail closed.

The workload UAMI is attached to API and worker and independently attested. Its
Purview roles remain separate from the worker's exact eight Agent Identity Graph
roles. Effective readiness also requires a current verified tenant connection and
the exact active SIT generation. Installation is never policy or runtime proof.

All five hosted jobs passed for the subsequent Boolean-verifier correction.
The authorized replacement is partially deployed and stopped at database schema
verification. The model correction passes local relational comparison, and the
Resume correction passes 17 execution-binding regressions. Complete combined
acceptance and fresh independent review before the first bounded recovery. No live authority
transfers through Git, documentation, local evidence, or earlier deployments.
Preserve both deployments and all failed execution evidence. Cleanup requires
separate exact-target authority.


### Phase 5 — authorized live E2E

This phase started after Phase 4 and fresh user authority for the exact replacement
target. It is incomplete at the database stage described above. Resume only through
the verified, authorized recovery path after classifying and correcting the schema
mismatch. Authorization for a different or superseded target does not transfer.

From a clean checkout:

1. run `.\gateway.cmd setup` on Windows (and keep the core `./gateway setup` path
   valid on macOS/Linux);
2. complete Plan, explicit Apply or checkpoint-bound Resume, Verify, and Admin UI
   sign-in;
3. use Settings to connect Purview authority, select the approved SIT, configure
   the independent tenant KYD Group, and reach exact readback;
4. create one registration using the newly created bootstrap seed blueprint and
   one choosing **Create new blueprint**, producing exactly two new blueprints;
   require both core workflows to reach provider-verified `Active`;
5. in Settings, create one Individual DLP profile/rule for each newly resolved
   blueprint, prove each Ready independently, and enable its registration;
6. connect one external agent to each blueprint and exercise both agents;
7. verify per-agent Agent 365 observability attribution and accepted export;
8. verify Prompt Shields allow and block behavior independently for each agent; and
9. verify Purview DLP benign allow and approved synthetic sensitive block results
   for each blueprint, including attribution, scope, execution mode, and sanitized
   observability.

Success requires both agents and both blueprints to satisfy every relevant
assertion. One successful profile, an HTTP success, policy readback, role
assignment, local test, or platform `Running` state cannot stand in for the other
evidence. Record environment-specific identifiers only in ignored or
access-controlled evidence, then update the public deployment checkpoint with the
non-sensitive outcome.
