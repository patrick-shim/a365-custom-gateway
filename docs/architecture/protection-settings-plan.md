# Protection configuration architecture

Bootstrap, registration, hosted UI Settings / Data protection, and runtime
protection contracts. Product-level scope, expected behaviors, and UI platform
(React + Fluent for all UIs; C# backend) are in the
[product brief](../spec/product-brief.md) and [UI design](../console/design.md).

Much of the Settings wording below still describes the **legacy Blazor Admin UI**
tasks that bootstrap deploys today. Target Console IA places the same contracts
under Data protection / Platform. Configuration, current readiness, and observed
provider behavior remain separate facts.

## Ownership

| Area | Capability preparation | Application configuration |
|---|---|---|
| Agent 365 Registry beta | Deployment-wide environment and identity admission | Display capability; signed-in Administrator completes each registration |
| Prompt Shields | Shared Content Safety resource, managed-identity role, endpoint and readback | Deployment defaults, independent per-agent use and effective status |
| Purview | Runtime/automation identities, permissions, certificate, Windows execution path and capability readback | Tenant connection, inventory, KYD, shared blueprint policy, reviewed configuration and runtime tests |

Guided fresh setup includes shared Azure AI Content Safety for all presets.
**Full evaluation** includes Purview prerequisites; **Core Gateway** omits Purview
prerequisites; **Custom** chooses Purview independently. Agent-level Prompt Shields
use remains optional. The source retains disabled legacy Content Safety
configuration for source-bound recovery. An unavailable quota does not silently
change SKU or remove the service from a fresh guided plan.

Bootstrap prepares capabilities and verifies their exact resource/identity
bindings. It does not select sensitive information types or author tenant policies.
Local configuration tests do not establish provider or hosted workflow readiness.

## Focused Settings tasks

The current application uses `/settings` as the protection overview and
`/settings/connection`, `/settings/policy`, `/settings/runtime`,
`/settings/collection` and `/settings/defaults` for the individual tasks.
Only the selected task's editors are shown. Overview is available to control-plane
roles; permitted governance reads remain distinct from administrator-only
inventory, review, mutation, runtime execution and defaults.

Core registration can be complete with both per-agent protections intentionally
Off. Off is neutral, not an unfinished protection task; missing state is Unknown,
not Off. Overview, list, details and Settings use the same protection projection
to distinguish installed capability, saved choice and current protection.

## Shared scope and independent usage

Know Your Data uses the fixed tenant-wide enterprise-AI-apps location
`ee1680d0-702f-4090-b26c-c49091e86531`, with Entra Group scope. A DLP profile uses
one reusable blueprint application ID with Entra Individual scope. Both use the
Application enforcement plane.

One blueprint profile is shared by registrations using that blueprint. Individual
does not mean per-agent isolation. A policy change can affect other agents and
requires acknowledgement of that impact. Switching one agent's Purview use off
does not turn off or delete the shared policy.

Prompt Shields and Purview choices are independent. Requested choices, configured
policy, capability availability, simulation and effective enforcement must be
reported separately. Ordinary registration can proceed without optional per-agent
protection.

In the current registration UI, an On default remains a requested choice even
when its installed capability or profile prerequisites are unavailable. It is
not silently downgraded to Off. The administrator must resolve the prerequisites
or explicitly turn the choice off before the reviewed registration can proceed.
This preserves fail-closed runtime behavior; it does not declare an unavailable
control effective.

## Tenant connection and inventory

An Administrator starts a reviewed, confirmed connection operation for the exact
tenant. The bounded Windows companion performs interactive compliance sign-in and
returns typed identity, authorization and inventory facts. The Gateway rechecks
actor, operation and authority before accepting them. Provider tokens and
certificate material are not returned through that handoff.

The current task gives ordered download, PowerShell 7, per-file trust, full
command, official sign-in and result-paste instructions. A blocked script cannot
unblock itself; the separate, organization-permitted `Unblock-File` step removes
only the download marker. Enforced signing requires an approved signed script,
not a policy override. Direct paste is the primary result handoff; optional file
upload uses the same strict, bounded parser and exact review bindings. Neither
path retains raw output after submission or leaving the task. The finite 1 MiB
Interactive Server message limit accommodates valid inventories above the
default 32 KiB while preserving 512 KiB UTF-8 and 384 KiB decoded input limits.

**Go to companion result** scrolls to the paste field on the same operation.
The browser's scroll fragment can differ from the server navigation URI and is
not part of operation identity. Recovery retains that fragment, checks the same
origin/path and other query context, and awaits acknowledgment of the exact
original operation ID before confirmation or completion. If that acknowledgment
fails, the UI explicitly says no confirmation or protection change was sent for
this action and directs the user to reload, check status and review again.
JavaScript failure, circuit disconnection and timeout cannot silently proceed.
Only the operation ID and safe failure type are logged. An uncertain response
after submission still requires readback, never a duplicate submission.

The helper reads sensitive information type definitions, not prompts or
documents. It does not create a DLP policy, enable protection or transfer the
administrator's PowerShell session. Submitting its result authorizes the
Gateway's own independent app-access check. Connection verification must succeed
before subsequent policy configuration and runtime verification can proceed.

The completed task shows an explained outcome rather than ending at a technical
log. **Purview connection verified** describes the independent app-access check
and current classifier inventory, states that no policy or runtime blocking was
tested, and offers **Continue to shared policies**. Pending work is observed by
GET every three seconds for a bounded five-minute session. The user can stop or
resume these reads; stopping observation does not cancel the operation. Terminal
readback refreshes the connection and inventory before offering onward actions.
Errors, expiry and incomplete readback keep stale readiness unavailable.
Read selection and refresh success share the current task's dependencies; an
unrelated earlier policy blueprint error cannot block connection recovery.
Runtime-readback updates also reschedule parent readiness expiry, so a shorter
replacement lifetime removes current enforcement claims without a manual reload
or rebinding private samples.

**Technical operation details** stays available as a collapsed disclosure.
Connection operations intentionally skip policy mutation, policy propagation,
runtime-role attestation and runtime-sample verdicts. Each skip explains its
scope; it does not imply that a separate policy or runtime test passed.

Reopening the known operation can recover its accepted companion launch through
GET for the same actor while it awaits administrator completion. The command must
still match the original tenant, operation, actor, inventory generation and
expiry. Readback does not extend that expiry or start a replacement connection.
Wrong/stale evidence is rejected. Connection shows the validated inventory count,
not a selection control. The optional collection task retains its own meaningful
single-SIT choice; reloading that inventory requires explicit review of an earlier
choice rather than silently rebinding it.

An expired waiting connection can start a separately reviewed authorization.
For a retained operation, the UI checks its actor, tenant, target and exact
accepted launch/expiry binding before offering **Review connection refresh**.
Without a retained operation reference, review still binds the current expired
connection and row version. Confirmation creates a new operation and inventory
generation; it does not extend the old launch. Live or uncertain handoffs,
pending verification and mismatched retained bindings remain blocked.

Sensitive information types (SITs) come from the current tenant inventory. A
selection binds GUID, exact Unicode name and inventory generation; it does not
come from a static catalog or free-text name. Expired inventory, missing/renamed
types or changed authority requires renewed review.

The current verifier gives connection and inventory evidence a 15-minute lifetime.
Runtime certification is bounded by that inventory expiry as well as the maximum
30-minute sample-evidence age, so effective readiness can last less than 15 minutes.
An expired connection is not usable. Refresh produces a new inventory generation;
it does not silently rebind or reauthorize a saved shared profile. The UI supports
explicit current-inventory re-review. There is no unattended renewal promise.

The task navigation is an ordered guide: **Connect tenant**, **Set shared
policy**, **Test behavior**, then **Review agent choices**. Its highlight shows
the current location, not a completed prerequisite. Administrators can revisit a
step; disabled actions explain their missing prerequisites. Optional collection,
overview and defaults remain separate tasks. The policy editor precedes collapsed
saved-policy details, and opening an existing policy for editing moves keyboard
focus to that editor.
A completed operation from a different task is retained under **Completed earlier
task**, so it cannot look like completion of the new step. Pending, failed or
unreadable work remains visible rather than being collapsed as successful history.

If a shared-policy operation fails or becomes uncertain, retain its exact
operation/profile and read its status. A native read timeout and expired
inventory are different from an invalid SIT choice. No provider IDs or no final
readback does not prove that Microsoft objects are absent. Renew expired
connection authority first, then use **Review existing policy check** for the
same saved policy rather than creating another one.

That reconciliation review validates the unchanged saved settings against the
connection's genuinely current inventory generation. Reviewing or confirming
alone changes no profile binding. Acceptance checks exact tenant/connection,
blueprint, profile/version, mode, selections, thresholds and activity/action
scope again. Its transaction can then update the profile's generation/expiry and
clear prior propagation/token/runtime proof, preserving provider IDs, settings
and agent choices. The worker still performs read-only Microsoft reconciliation;
a partial, absent, mismatched or unknown result is not an automatic create/update.

Profile-specific links preserve the exact selected policy through configuration
and behavior testing. Invalid, missing or duplicate profile identifiers fail
explicitly rather than selecting a substitute. A saved Enforce policy with exact
configuration checks leads to approved examples, not an enforcement claim.
Approved results are compared with the current profile separately from the
historical receipt. Off and simulation lead onward without requiring blocking
tests. The resulting summary points to each agent's own Purview choice and to
separate evaluated-traffic and destination-delivery checks; a shared-policy save
or test does not enable an agent. No next-step link performs a mutation.

The automation identity also needs the exact Security & Compliance service-principal
reference checked by the executor. Entra application/role/certificate preparation
does not itself create that separate provider reference in the retained flow.
Treat its absence as an explicit connection prerequisite, not permission to
remove verification or broaden roles.

The DLP profile supports 1-100 distinct selected SITs with OR semantics: any
selected type can match. Duplicate or ambiguous catalog bindings are rejected.
Each type keeps its own count and confidence thresholds; counts
are not summed across types. Minimum count is positive; maximum count is -1
(unbounded) or at least the minimum. Confidence bounds are inclusive from 1 to
100, with maximum at least minimum. Existing shared policy edits require explicit
threshold evidence; unknown values are not silently replaced with defaults.
New selections start visibly at minimum count **1**, maximum **Any** (`-1`),
and confidence **75-100**. Search and select types first, then review each
selected type's thresholds in a separate section. Deselecting and reselecting an
edited draft retains those edits; loading a legacy profile does not invent
missing evidence. Refreshing prerequisites reads saved state, preserves an
unsaved draft, and never itself renews authorization.

## Policy modes

The API/domain modes map to provider modes as follows:

| API/domain mode | UI wording | Provider mode | Meaning |
|---|---|---|---|
| Enforce | Enforce | Enable | Requires current runtime certification before effective enforcement |
| SimulationWithTips | Simulation with policy tips where supported | TestWithNotifications | Nonblocking simulation; tips depend on provider support |
| SimulationWithoutTips | Silent simulation | TestWithoutNotifications | Nonblocking simulation without tips |
| Disabled | Configured off | Disable | Policy remains configured and disabled |

Legacy Enforce maps to Enforce; legacy AuditOnly maps to
SimulationWithoutTips; unknown legacy/current modes require review instead of
becoming simulation. SimulationReady and Disabled preserve verified
configuration facts without claiming an allow/block enforcement result.

The retained rule contract uses supported activity/action pairs. Offline
DownloadText processing cannot establish response-side blocking. Changing a
shared mode, classifier or threshold invalidates protection proof tied to the
prior configuration.

## Registration and later editing

The same reviewed configuration service supports registration, agent editing and
Settings. A registration can reuse an already verified profile or submit a
reviewed and confirmed configuration intent.

For an existing blueprint, the operation binds to its exact application ID and
checks shared impact and optimistic concurrency. For **Create new blueprint**, the
review binds to the generated external ID and requested blueprint name. Its
accepted operation enters AwaitingBlueprint, with the original actor, intent hash
and consumed confirmation retained.

After core provisioning reaches Active, an internal worker continuation verifies
the new registration/blueprint binding and current connection/inventory. It
creates the bound profile and queues protection work atomically with the
continuation. An existing-profile conflict or expired authority yields a manual
review action; it does not silently adopt another policy or invent new consent.

This separation preserves the seven-stage core registration workflow. A
configuration request is not proof that the agent is already protected.

## Review, confirmation and authorization

The API enforces delegated Administrator authority for protection mutation and
rechecks tenant, user object ID, target, operation and payload. Operator, Auditor
and SupportReader access is restricted to their allowed status views.

Reviews bind the exact tenant, blueprint/scope, inventory, selected SITs and
thresholds, mode, activities/actions and shared-policy impact. A short-lived review
value is exchanged for a single-use confirmation. Mutation also checks canonical
UUIDv4 idempotency and row-version concurrency. A review response alone does not
authorize execution.

Changed scope, inventory, payload, actor, row version or expiry invalidates the
confirmation. Errors use bounded codes and correlation IDs. Browser refresh
recovers durable operation state, not a reusable interactive sign-in or secret.

Ordinary starts use the review token ID as the operation ID. Completion has a
separate approval but resumes the reviewed original connection `SourceOperationId`.
Settings retains that execution/recovery ID in the browser URL and awaits
acknowledgement before confirmation/mutation; failed retention sends neither.
The confirmation remains bound to its approval. Unknown results recover the same
operation by GET, not another create or a newly manufactured review. An old
Submitted completion approval can be followed once through its validated
`ReadbackReferenceId`; both operations must match their identity, type and target
bindings. Cancellation, disposal, changed context and late callbacks cannot
replace the current task or reuse an old confirmation.

See the [API contract](../api/api-contract.md) for request fields and routes.

## Durable policy administration

Ordinary provider operations use a transactional outbox and the dedicated
`gateway-protection-admin-v1` queue. Their eight persisted stages are:

1. Validate Reviewed Intent.
2. Discover Provider State.
3. Apply Reviewed Mutation.
4. Record Exact Readback.
5. Verify Propagation.
6. Attest Token Roles.
7. Validate Runtime Verdict.
8. Complete.

These stages are distinct from registration workflow v3 and
`gateway-provisioning-v3`. Each operation retains reviewed intent and exact
provider identifiers. Unknown writes require exact readback rather than blind
repetition. The worker uses the private
[Windows executor](purview-windows-executor.md) for certificate-backed compliance
operations.

Capability installation, directory-role assignment, policy readback, propagation,
runtime-token roles and observed behavior remain separate facts. A platform
Running state is not policy or data-plane proof.

## Approved runtime sample tests

The current runtime-test API provides:

- `POST /api/v1/protection/purview/dlp-profiles/{id}:review-runtime-test`
- `POST /api/v1/protection/purview/dlp-profiles/{id}:test-runtime`
- `GET /api/v1/protection/runtime-tests/{operationId}`

Review binds a synthetic sample manifest and exact deployment, profile,
registration, inventory and mode context. After confirmation, execution verifies
sample hashes and limits, commits acceptance, then runs provider work
synchronously. Raw samples remain ephemeral; they are not sent through the
protection queue or stored in operation records.

The browser keeps raw samples in private JavaScript, never bound to the Blazor
circuit. Explicit execution crosses the real administrator-only HTTPS portal
with antiforgery and bounded body validation, then one Gateway execution POST.
Role, clock, inventory, profile and review bindings are rechecked; reset/close
erases browser-held samples, and uncertain execution recovers only a safe report.
The saved-report view separates historical results from refreshed profile
readiness and rejects mismatched routes or contradictory verification metadata.

A batch supports up to eight positive samples plus its negative sample, 8 KiB per
sample and 64 KiB total. The backend execution deadline is 60 seconds, driven by
the injected clock and applied to awaited dependencies. Deadline/cancellation
does not prove remote work was undone. Durable status
retains sanitized observations and distinguishes behavior observed, submission
accepted, not verified, failure and unknown outcomes.

Enforce proof requires the negative sample to be allowed and positive samples to
be blocked through content processing. A protection-scope response alone does not
prove sample behavior. Simulation can report nonblocking observations or accepted
submission without claiming enforcement. Disabled mode cannot run a test.

An administrator's association between a sample and a SIT is not provider-reported
classifier attribution; the runtime result reports SIT match attribution as
unavailable. Certification is limited by current context and evidence expiry,
including a maximum evidence age of 30 minutes. Changed context invalidates old
proof. Recovery does not repeat an uncertain sample submission.

## Prompt gate and readiness

The shared `ProtectionStateProjection` and `ProtectionSnapshot` keep capability,
saved mode, profile state and operation progress separate. In particular,
`features.purviewProfileStatus` is not `purviewConfigurationStatus`.
`readiness.validUntilUtc` is an optional snapshot bound: the earliest current
connection/inventory expiry, capped by runtime evidence for Enforce. Equality
invalidates a positive current badge. Missing expiry cannot establish current
enforcement, and a context change can invalidate the snapshot before its deadline.
The UI refreshes time-dependent presentation at known expiry boundaries; it does
not renew provider evidence or gain authority from that timer.

Prompt Shields requires exact installed Content Safety readback. Purview Enforce
requires the exact shared profile, current capability/tenant/inventory, propagation,
token-role evidence and valid runtime certification. Missing requested
enforcement remains fail-closed rather than silently turning off protection.

Prompt receipts bind the registration protection revision and current context,
including shared policy mode and thresholds. They are single-use and expire no
later than their governing proof. Changes to effective protection invalidate prior
receipts.

## Compatibility and further work

Focused protection tasks retain explicit review, shared-policy impact and
exact-context recovery. A local fixture never establishes confirmation authority,
provider behavior or a longer evidence lifetime.

The source retains legacy combined profiles, review-required migration candidates
and legacy request fields. They do not establish readiness. Bounded
[upgrade operations](../../operations/gateway-upgrade.md) preserve original
bootstrap state and separately
bound upgrade receipts serve different operational purposes.

The minimum referenced tools and local test projects are present again. Reproducible
builds, regression tests, Chrome journeys and fresh hosted acceptance remain
distinct in M1 through M6, with whole-project synchronization at each closure.
No historical pass total or runtime receipt substitutes for those checklist items.
