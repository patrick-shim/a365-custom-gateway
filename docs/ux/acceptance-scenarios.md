# UX acceptance scenarios

These scenarios define the M3 core and M4 protection behavior and the invariants
each must preserve. They are acceptance specifications, not test results.
[MILESTONES.md](../../MILESTONES.md) is the sole completion record. Scenario IDs are
stable so screen designs, fixtures and later tests can refer to the same behavior.

## Verification boundaries

| Boundary | What it can demonstrate |
|---|---|
| M2 prototype in Chrome | Proposed wording, decisions, navigation, representative fixture states, keyboard behavior and narrow layouts. All identities, credentials, policy results and counts are synthetic. |
| M3/M4 production implementation | The real Blazor components, API authorization, validation, concurrency and database behavior using deny-by-default provider fixtures and the owned SQL fixture where transactions matter. A static prototype cannot establish these. |
| M5 release and M6 hosted acceptance | The exact packaged candidate and actual Microsoft identity, Registry, telemetry, Prompt Shields and Purview behavior. Local fixtures cannot establish provider permissions, delivery, propagation or enforcement. |

No scenario authorizes a live mutation. Existing authorization and project scope
remain governed by [AGENTS.md](../../AGENTS.md). Do not execute every operational
script as a test suite. Later implementation checks use the
[local baseline runner](../../tools/Test-LocalBaseline.ps1) and focused new tests.

## Milestone coverage

| Change scope | Acceptance scenarios |
|---|---|
| M3.1 Getting started and navigation | UX-01, UX-28–31, UX-33 |
| M3.2 New/reused blueprint registration | UX-02–04, UX-16, UX-24, UX-28–31 |
| M3.3 Endpoint, ID and one-time key handoff | UX-05–06, UX-30–32 |
| M3.4 Provisioning and administrator handoff | UX-07–09, UX-28–31 |
| M3.5 External-agent generation gate | UX-10–11, UX-32 |
| M3.6 Cursor, search and totals | UX-12–13, UX-29–31 |
| M3.7 Lifecycle, credentials and history | UX-06, UX-14–15, UX-28–31 |
| M3.8 Core regression and browser review | Relevant core scenarios above in the production implementation |
| M4.1 Optional protection tasks | UX-16, UX-28–31, UX-34 |
| M4.2 Consistent protection summaries | UX-17, UX-22, UX-26, UX-34 |
| M4.3 Companion connection and inventory | UX-18–19, UX-28–31, UX-34 |
| M4.4 Shared policy configuration | UX-20–21, UX-23–24, UX-34 |
| M4.5 Policy modes and independent Prompt Shields | UX-11, UX-16–17, UX-22, UX-34 |
| M4.6 Approved runtime samples and evidence | UX-25–27, UX-28–31, UX-34 |
| M4.7 Protection regression, browser and API review | Relevant protection scenarios above, including UX-34 and request/response schema checks |

M3.9 and M4.8 remain whole-project synchronization requirements in the milestone
checklist; this document does not replace them.

## Core journeys

### UX-01 — Find the next useful task

**Given** a signed-in administrator and a verified installation with no agents,
**when** they open Overview or Getting started,
**then** the primary action is to register an agent, and the explanation names
the external agent, Gateway ID/key and later Microsoft registration handoff.
Optional protection tasks are separate from core registration progress. An
unselected capability is not shown as an unfinished mandatory task.

**Given** a non-administrator, **when** the same empty view opens, **then** it
offers the permitted reading path and explains that an administrator registers
agents; it offers no unusable create action. Missing prerequisites name the
specific task and actor, without claiming the installation or protection works.

**Verify:** M2 navigation/copy fixtures; M3 actual routes, role guards and API reads.
Grounding: R1, R3, R9.

### UX-02 — Register with a new blueprint

**Given** an administrator, an admitted registration flow and known deployment
defaults, **when** they choose Create new blueprint and enter valid agent and
blueprint details, **then** the review shows the generated immutable external ID,
owner, environment, blueprint name and the actual feature choices. The new-mode
request has a blueprint name and no existing blueprint object ID.

**When** the accepted create completes, **then** one Gateway registration, its
credential, workflow, audit events and outbox work are committed together. The
screen shows the key handoff before leaving for Registry completion. The worker
resolves the new reusable blueprint and a distinct child identity; the UI never
uses the Gateway record ID as a Microsoft identity ID.

**Verify:** M2 review/key sequence; M3 component/API/SQL/provider fixtures; M6 real
new-blueprint registration. Grounding: R2, R4.

### UX-03 — Register with a compatible existing blueprint

**Given** an administrator and a catalog containing compatible and incompatible
blueprints, **when** they choose Use existing, **then** selection identifies the
exact catalog object and compatible application identity. No new blueprint name
is submitted. An empty, stale, duplicate or incompatible catalog response blocks
submission with an actionable refresh or selection message.

**When** two agents reuse the same blueprint, **then** they keep distinct Gateway
registrations, ingress credentials and child Agent Identities. Any shared Purview
profile is identified as shared before selection or editing. A sibling cannot use
another child's prompt receipt or key.

**Verify:** M2 selection states; M3 catalog/SQL and identity-binding tests; M6
actual reuse. Grounding: R2, R4, R5.

### UX-04 — Validate and recover registration without creating duplicates

**Given** missing required fields, conflicting blueprint modes or conflicting
feature representations, **when** submission is attempted, **then** errors name
the field, preserve other input and focus the first error. No create request is
sent by the UI until local validation succeeds; server validation remains decisive.

**Given** a valid submission, **when** the button is double-clicked or Enter is
pressed repeatedly, **then** only one request is in flight. If the response is
lost, the UI says the outcome is unknown and directs status lookup by the retained
external ID. It does not silently resubmit, generate a new external ID or claim
the create failed. A duplicate external-ID response resolves to the existing
registration; any lost key follows UX-06. This does not invent registration POST
idempotency or clear-key recovery.

**Verify:** M2 invalid/busy/unknown fixtures; M3 actual request counting, unique
registration and transaction rollback tests. Grounding: R2, R4.

### UX-05 — Save the one-time key before Registry handoff

**Given** a successful registration response containing a clear key,
**when** the handoff screen opens, **then** it groups the API endpoint, external
agent ID, key ID/expiry and one-time key with an explicit instruction to save the
key in the external agent's protected configuration. The sample command contains
no real key. The user acknowledges saving the key before continuing to a route
that may redirect for delegated Microsoft authentication.

**When** Copy succeeds, **then** visible and announced feedback identifies what
was copied. A clipboard denial shows a selectable fallback and never says Copied.
Navigation warns before discarding the unsaved one-time value; returning after
discard does not fetch it again. The application does not persist the clear key
in browser storage, URLs, audit, telemetry or ordinary logs. It does not claim
that it can erase the user's clipboard.

**Verify:** M2 synthetic copy/navigation behavior; M3 real component lifecycle,
clipboard rejection and absence-of-secret checks. Grounding: R2, R4, R12.

### UX-06 — Replace a lost key and revoke the old key safely

**Given** a lost key and an administrator viewing credential metadata,
**when** they issue a replacement, **then** a new key is displayed once and the
old usable key remains valid until explicitly revoked. The flow explains how to
update and verify the external agent before selecting the old key for revocation.

**When** the administrator confirms revocation, **then** the exact registration
and key ID are named; repeated revocation reports the existing revoked result
without another revocation audit. Revoking another agent's key fails. Revoking
the last usable key is blocked by the server. An interrupted issuance requires
metadata reconciliation; it never offers to recover an already-discarded secret.

**Verify:** M2 replacement/revocation review; M3 component/API and real SQL
credential, last-key, expiry and atomic-audit tests. Grounding: R4, R1.

### UX-07 — Complete Registry creation through the signed-in administrator

**Given** a workflow paused at the delegated Registry step,
**when** an authorized signed-in administrator completes it manually or through a
permitted automatic attempt, **then** the request uses delegated administrator
authority for that exact operation. Automatic initiation happens only after key
handoff and current eligibility checks; it does not bypass required sign-in,
consent or Conditional Access.

**Given** no delegated token, an app-only principal, another actor's persisted
attempt, or an ineligible workflow, **then** creation stops before provider POST.
The page names the required administrator action. Worker redelivery cannot
substitute its application identity. One durable attempt permits at most one
Registry create POST; acceptance queues verification rather than claiming Active.

**Verify:** M2 handoff/consent fixtures; M3 policy, handler and finite provider-call
tests; M6 delegated identity/consent. Grounding: R1, R6.

### UX-08 — Reconcile an unknown Registry outcome

**Given** a lost Registry create response, **when** the page is refreshed,
reopened or its permitted reconciliation action is selected, **then** it reads
the persisted Gateway operation. Any permitted provider reconciliation uses the
exact persisted planned registration ID; ordinary page refresh does not itself
promise a Microsoft readback. It does not issue another create POST or choose a
replacement ID. Provider readback must match the expected Registry record,
source agent, identity, blueprint, owner and creator.

**Given** an initial 404 followed by a matching record, **then** bounded readback
can continue the existing workflow. Persistent absence, conflicting binding or
exhausted budget remains an actionable unresolved result. A generic Retry button
must not convert it into another create attempt.

**Verify:** M2 unknown-state copy and allowed action; M3 crash/reopen/provider
fixtures asserting one POST; M6 bounded operational recovery. Grounding: R6.

### UX-09 — Show durable progress and honest reopening behavior

**Given** pending, running, awaiting-administrator, failed and completed workflow
fixtures, **when** their operation pages open, **then** the current step, completed
steps, next actor/action and safe correlation identifier are understandable.
Polling is bounded; reaching the limit offers a read refresh instead of a
permanent spinner or fabricated failure. Read errors retain any prior status as
stale, not as freshly verified progress.

**When** the user leaves and reopens, **then** persisted state drives the page.
Completed steps are not rerun. Active is shown only after final registration
verification and remains separate from optional protection or telemetry results.

**Verify:** M2 progress/reopen fixtures; M3 durable worker recovery and production
UI tests; M6 hosted reopen. Grounding: R6, R9.

### UX-10 — Evaluate before invoking the model

**Given** an external-agent integration and a callback that records model calls,
**when** evaluation returns Allowed with a valid, nonempty, unexpired receipt,
**then** the callback runs once and ingestion uses that receipt with the exact
prompt/content type and agent identity that were evaluated.

**Given** blocked, malformed, missing, expired or unavailable evaluation proof,
**then** the callback and interaction submission do not run. Denial identifies
the decision without exposing sensitive dependency bodies. No automatic retry
starts generation after that outcome.

**Verify:** M3 real sample callback/clock/transport tests, API and SQL receipt
tests; M6 complete external-agent interaction. A prototype can explain the gate
but cannot prove it. Grounding: R5.

### UX-11 — Reject invalidated proof without repeating generation

**Given** proof already known to be stale or expired before the callback,
**when** the gate checks it, **then** no model call begins. Receipt equality with
the expiry time counts as expired. Wrong child, changed prompt/content type,
consumed receipt and changed identity/protection revision cannot authorize
protected ingestion.

**Given** protection changes or proof expires while the model is running,
**when** the resulting interaction reaches the API, **then** the API rejects the
obsolete proof before staging protected content. The sample reports the outcome;
it does not rerun generation or evaluate the old prompt afterward to retrofit
proof onto the existing response. This also applies when a shared blueprint
policy changes or Prompt Shields/registration enablement changes.

The before-staging expectation applies when the context is already invalid at
the API's initial check. A change racing later ingestion can occur after a
provider call or Blob staging but before the final SQL guard. That final guard
must reject invalid proof; the UI must not claim that every rejected race had
zero external side effects or that all staged content was automatically undone.

The client cannot infer every server change from an earlier receipt alone. This
scenario does not promise an atomic boundary between a remote policy update and
an external model callback. Off/simulation never turns an otherwise required
Prompt Shields receipt into optional proof.

**Verify:** M3/M4 controlled-clock, configuration-change and SQL race tests; M6
provider-backed policy transitions. Grounding: R5, R7.

### UX-12 — Traverse every page beyond 100 agents

**Given** a stable fixture with 237 registrations, including equal creation
timestamps, **when** the user advances through 100-item pages, **then** the pages
contain 100, 100 and 37 distinct agents in stable creation-time/ID order. The final
page has no enabled Next action. Returning to prior pages preserves their query.
The exact API-provided opaque cursor round-trips without manual rewriting.

**When** a filter changes, **then** paging restarts with that query. A malformed
cursor returns a safe validation response and a restart-list action, not a raw
parse exception. Concurrent fleet changes are resolved by refreshing the query;
the UI does not claim a database snapshot unless the API provides one.

**Verify:** M2 synthetic paging; M3 handler/repository cursor integration and
production UI tests. The source now uses one versioned cursor codec and SQL GUID
ordering; final-page lookahead must also handle an exactly full page. Grounding: R3.

### UX-13 — Search both names and external IDs; count the whole result

**Given** a fixture where one agent's name and a different agent's external ID
contain `invoice-eu`, **when** the user searches that fragment, **then** both match
under the documented matching rule; unrelated agents do not. Status/environment
filters combine with the search, persist across pages and are cleared explicitly.

**Given** 137 filtered results within a 237-agent fleet, **when** the first
100-item page opens, **then** it reports 100 shown of 137 matches. Overview fleet
totals account for all 237 eligible registrations, not the loaded page. Zero
matches is distinguished from an empty fleet. Missing totals show an unavailable
count rather than zero. Search and total semantics must agree between API and UI.

**Verify:** M2 fixture counts/search; M3 repository tests over more than 100
records and overview/list consistency. The source implements name/external-ID
search and authoritative filtered totals; keep testing null totals and read
failures rather than substituting page lengths. Grounding: R3.

### UX-14 — Enable, disable and delete with truthful scope

**Given** an eligible registration, **when** an administrator or operator changes
enablement, **then** the review names the agent and the effect on Gateway use;
only permitted state transitions are offered and the server enforces them.
Disabled/deleted agents cannot continue protected ingestion with old proof.

**Given** an administrator deleting a registration, **when** the confirmation
opens, **then** it says removal is from the Gateway and that Microsoft identities
and other external resources are preserved. Confirmation cannot promise their
cleanup. Cancel sends no mutation. Accepted asynchronous deletion links its
operation; an unknown response is reconciled before any new action.

**Verify:** M2 reviews and restricted-role states; M3 state/receipt/audit tests and
production deletion wording. Grounding: R1, R4, R5, R6.

### UX-15 — Navigate history without leaking or inventing evidence

**Given** related registration, provisioning, protection and audit records,
**when** an authorized reader follows a contextual link, **then** it opens the
matching record, preserves a useful route back and shows safe IDs, actor, time
and recorded outcome. The page distinguishes submission, processing and verified
completion. Secrets and raw samples are absent from history.

**Given** a role without the target permission or an unavailable/deleted record,
**then** the link is hidden or explained as restricted, and direct navigation
shows safe access-denied/not-found behavior. Operator access to provisioning
history does not imply audit access; auditor access to audit does not imply
provisioning operation access.

**Verify:** M2 navigation/restriction fixtures; M3 real role-scoped requests and
audit links. Grounding: R1, R6, R9.

## Protection journeys

### UX-16 — Keep optional capabilities independent

**Given** a registration with Prompt Shields and Purview intentionally off,
**when** onboarding or details open, **then** core registration can be complete
without a protection error. Installed capability, current selection and actual
runtime result remain separate. Off never means missing or unknown data.

**When** the administrator changes either optional protection or either telemetry
destination, **then** the other choices are not silently enabled or disabled.
Requesting a capability without its current prerequisite binding fails with a
specific next task; it is not silently saved as off. Reusing a blueprint never
silently edits its shared policy as a side effect of an unrelated toggle.

**Verify:** M2 all-off and mixed combinations; M4 component/API/readiness tests.
Grounding: R2, R5, R7.

### UX-17 — Use the same state meaning everywhere

**Given** the same registration/profile snapshot, **when** it appears in Overview,
the agent list, details and Settings, **then** each view agrees on capability,
requested mode and effective status. Enforcing requires current capability,
readback, propagation, role and runtime evidence for the exact binding.

**When** evidence expires or changes, **then** the summary stops claiming current
enforcement and names the missing verification. Installed, Configured, Active,
Off, Simulation, Verifying, Unavailable and Action required do not substitute for
one another. Action required names the actor and next action; a stopped/unknown
operation is not described as actively verifying.

**Verify:** M2 shared fixtures/copy; M4 projection/component tests with time and
version changes; M6 actual evidence. Grounding: R7, R10.

### UX-18 — Bind the Windows companion to the intended administrator task

**Given** an administrator starting tenant connection,
**when** the Windows companion instructions are shown, **then** they identify
the expected tenant/account, operation, inventory generation and launch expiry.
Authentication remains in the authorized Microsoft flow; no credential is copied
into a command or form. Copy feedback follows UX-05.

**Given** a first-time Windows download, **when** instructions appear, **then**
the explicit review-and-trust step precedes the full connection command. Its
copyable `Unblock-File` targets only the downloaded companion, explains that no
output is normal and never lowers execution policy. A blocked script cannot
perform that step itself. Enforced signing or a prevented download requires the
organization's approved route, not a bypass.

**Given** the helper's console result, **when** it is pasted into **"Paste
companion result"**, **then** no manually created file is required. A saved
UTF-8 file remains an optional secondary path using identical validation.
Surrounding whitespace is accepted; extra console output, multiple result lines,
reference-repair output and raw JSON are not. Test an actual 354-definition
synthetic result above 32 KiB through Chrome without disconnecting the circuit,
while retaining the 512 KiB input and 384 KiB decoded limits. Editing, clearing
or replacing input invalidates earlier evidence/approval; an old file read
cannot overwrite a later paste. Interrupted file reads explicitly offer paste.
The field, optional-upload disclosure and review are usable by keyboard, at
360/390-pixel widths and actual 200% browser zoom. Raw pasted text is cleared on
submission, task change and disposal.

**Given** a current waiting connection and valid companion output,
**when** the administrator clicks **Go to companion result**, pastes, reviews
and submits without reloading, **then** the same-page scroll fragment does not
invalidate recovery retention. The browser must acknowledge the original
operation ID before exactly one completion using its separate approval.
Changing origin, path, other query context or the intended recovery ID remains
rejected; a duplicate recovery parameter cannot dispatch.

**Given** missing browser acknowledgment, JavaScript failure, disconnection or
timeout before confirmation, **when** submission stops, **then** explain that no
confirmation or protection change was sent for this action and give the
reload/status/review steps. Preserve still-valid evidence and the original
operation; discard the local approval. Do not show raw exception details, claim
connection failure or use this safe-before-dispatch explanation for an unknown
result after mutation.

**Given** wrong actor, wrong tenant, replaced generation, expired launch or
altered evidence, **when** completion is submitted, **then** it fails before
being accepted as a connected tenant. Closing an unconfirmed dialog or cancelling
interactive authentication leaves no success claim. Closing a page after the
operation was accepted does not undo it: reopening reads its actual waiting,
expired or completed state. The design does not invent a provider rollback or a
generic cancellation API.

**Given** a valid helper result and a separate completion approval,
**when** the administrator confirms, **then** the browser acknowledges retention
of the original reviewed connection ID before confirmation/submission. The
returned original ID is accepted; an approval or unrelated ID is not. Acceptance
says **“Companion result received. Checking Gateway access.”**, not Connected or
DLP enabled. The helper reads classifier definitions, not prompts/documents,
creates no policy and transfers no administrator sign-in session.

**Given** a lost completion response or an older Submitted approval URL,
**when** the task reopens, **then** GET resolves the original operation without
another confirmation or completion POST. An approval reference is followed only
after checking its source ID and both records' tenant, actor, type, target and
accepted state. Invalid references, disposal and late responses cannot replace
the current task. Pending/unknown completion hides the helper and duplicate
submission controls.

**Given** independent provider verification fails,
**when** its state is read back, **then** the connection resource
`VerificationFailed` and operation `Failed` render Failed, including after the
old expiry. Show **“Connection verification failed.”**, a bounded failure
reference and correlation ID. Explain that administrator sign-in did not verify
Gateway app access or enable DLP. Connection and timeline times are explicitly UTC.

**Given** a known expired waiting connection, **when** its permitted administrator
chooses **Review connection refresh**, **then** a fresh review and confirmation
precede a new operation and launch. The existing operation is retained, its expiry
is not extended, and its old evidence remains invalid. Live handoffs, pending
verification, unknown outcomes and mismatched retained bindings do not gain
automatic restart permission. Without a retained operation reference, the new
review still binds the current tenant connection and its row version.

**Verify:** M2 instructions and separate simulated submission/verification;
M4 paste/file parity, size/expiry/edit/race guards, distinct-ID binding,
lost-response/legacy-link recovery, disposal and actual failure-state tests plus
Chrome; M6 real Windows authentication and independent
provider verification. Grounding: R8.

### UX-19 — Refresh inventory without silently changing selections

**Given** selected sensitive information types from a saved inventory generation,
**when** that generation expires, changes or belongs to another tenant,
**then** configuration/review is blocked with a refresh task. A friendly name
alone cannot match a different identifier or resolve duplicate catalog entries.

**When** the user refreshes and reopens the task, **then** it loads current
inventory, flags changed/missing selections and requires a new review before
mutation. Previously accepted connection or policy state is not rewritten as
failed merely because an unsubmitted local edit was cancelled.

**Verify:** M2 stale/empty/error fixtures; M4 exact-ID/name/generation/expiry
validation tests. Grounding: R8, R10.

### UX-20 — Review the actual shared policy scope

**Given** several registrations sharing a blueprint,
**when** an administrator edits its DLP profile, **then** the review names the
blueprint application identity and shared profile and says the policy affects
every agent using that blueprint. It shows affected registrations/count only
when a complete authoritative set/count is available; a first-page list cannot
establish the impact total. The accepted mutation remains bound to
that exact blueprint/profile; a view scoped to one child cannot imply a
child-only policy change.

**Given** Know Your Data configuration, **then** the review instead identifies
the fixed tenant-wide Group location. DLP uses the blueprint Individual location.
Collection enablement is not a DLP policy mode. A selected classifier must not be
silently widened to All to enable full content capture.

**Verify:** M2 impact/scope review; M4 request binding/readback/affected-child
tests; M6 provider policy scope. Grounding: R7, R10.

### UX-21 — Review every selected classifier and threshold

**Given** a current inventory, **when** an administrator selects classifiers,
**then** 1–100 distinct sensitive information types from one generation are
supported and the review says that any selected type may match (OR). Each shows
its exact name and ID, minimum/maximum count and minimum/maximum confidence.
Count minimum is at least 1; maximum is Any (`-1`) or at least the minimum;
confidence is within 1–100 with maximum at least minimum.

**Given** a new policy, **then** proposed 1/Any/75/100 starting values are visible
and reviewable, not described as universally safe defaults. Unverified legacy
thresholds require explicit review instead of invented values. Invalid,
duplicate, mixed-generation or unsupported activity/action selections cannot
reach confirmation. The supported rule action remains UploadText/Block;
configured activities such as DownloadText do not prove response-side blocking.
The UI does not imply exclusions, bypasses or other rule actions exist.

**Verify:** M2 editing/review/validation fixtures; M4 boundary, normalization,
legacy-threshold and exact provider-readback tests. Grounding: R10.

### UX-22 — Preserve four modes and independent Prompt Shields

**Given** a reviewed shared profile, **when** the administrator selects Enforce,
Simulation with tips, Simulation without tips or Off, **then** the review and
saved summary preserve that exact mode. Provider representations remain mapped to
the four existing policy modes; the two simulation choices are not collapsed.

**Given** verified simulation configuration, **then** the UI says simulation,
not enforcing. Off does not collect runtime samples or call the policy for a
block demonstration. Neither setting silently turns Prompt Shields off: an
enabled shield may still deny a prompt and require proof. A mode change invalidates
incompatible receipts and runtime evidence rather than inheriting an old green
enforcement badge.

**Verify:** M2 all four fixtures with shield on/off; M4 serialization, policy
mapping, effective-state and receipt tests; M6 actual mode behavior/tips where
supported. Grounding: R5, R7, R10, R11.

### UX-23 — Confirm the reviewed version and handle concurrent edits

**Given** a review for an exact actor, tenant, payload and row version,
**when** it is confirmed and then executed, **then** both stages preserve that
binding. Cancelling before execution sends no policy/provider mutation; review
and confirmation may persist their operation/token state. Changing a field after
review discards the old confirmation; an expired review or confirmation cannot
be used. Expiry equality is expired.

**Given** another administrator edits the profile between review and execution,
**then** the stale edit is rejected, the current version can be reloaded and the
user reviews the new impact. No last-writer-wins overwrite or silent reapproval
occurs. Exact accepted-request replay returns the existing operation; reusing
its idempotency key for changed consent fails. Unknown outcomes follow operation
readback, not another provider mutation.

**Verify:** M2 changed/expired/conflict dialogs; M4 token, row-version, lock and
idempotency tests using real SQL where needed. Grounding: R10, R11.

### UX-24 — Bind deferred consent only to the new blueprint it reviewed

**Given** new-blueprint registration with reviewed Purview intent,
**when** the registration is accepted, **then** the screen distinguishes the
registration operation from protection awaiting the new blueprint. It does not
call that policy configured or enforcing before resolution.

**When** provisioning completes, **then** deferred intent binds only to the exact
created agent/external ID, requested blueprint name, original actor and reviewed
payload. Existing shared-profile conflict, expired authority/inventory or altered
intent stops automatic continuation and names the required fresh review. It does
not silently attach an unrelated profile, create duplicates or widen consent.

**Verify:** M2 waiting/action-required fixtures; M4 deferred-binding transaction,
replay and conflict tests; M6 real new-blueprint continuation. Grounding: R2, R10.

### UX-25 — Approve the exact synthetic runtime sample batch

**Given** an administrator and a current saved profile,
**when** they review synthetic positive and negative samples, **then** the review
identifies tenant, profile, shared blueprint, execution identity, exact saved
mode/thresholds and the batches to send. It explains the provider submission
boundary and requires explicit synthetic-sample acknowledgement and confirmation.
Review itself makes no runtime sample call.

**When** sample content, actor, profile/version or configuration changes, or review
expires, **then** the review is discarded and execution requires fresh consent.
Bounds are visible before submission: at most 8 positive samples per batch,
8 KiB UTF-8 per sample and 64 KiB per batch, with the required negative control.
Off collects no samples. Restricted roles never receive sample input controls.

**Verify:** M2 approval/changed/expired/off fixtures; M4 byte-boundary, context,
confirmation and interop tests. Grounding: R1, R11.

### UX-26 — Distinguish runtime observation from proven enforcement

**Given** a current Enforce profile and an approved batch,
**when** positive and benign control samples run, **then** the report compares
observed decisions with the expected sensitive-block/benign-allow behavior and
shows whether all required cases are covered. Accepted audit submission, absent
inline verdict, missing roles or incomplete batches cannot certify enforcement.

**Given** simulation or Off, **then** the current summary describes that mode
without claiming a block proof. Off cannot start a new sample execution; any
earlier report remains clearly historical. Simulation results remain separate from policy tips;
provider-specific behavior needs actual provider evidence. The report does not
claim which individual classifier matched when the provider does not disclose
that attribution. Evidence is tied to the current context and expires; old
results remain history rather than current protection.

**Verify:** M2 result fixtures; M4 evidence construction and certification tests;
M6 actual allow/block, mode and provider-output behavior. Grounding: R7, R11.

### UX-27 — Preserve unknown runtime outcomes and ephemeral samples

**Given** an approved runtime execution that times out, loses its response, is
interrupted or exceeds its 60-second execution deadline,
**when** the UI reopens status, **then** it retrieves metadata for that same
operation and distinguishes failed, partial and outcome-unknown results. It
never automatically resends samples or changes unknown into allow/block success.
Exact idempotent result lookup/replay must not rerun the provider. Any genuinely
new test requires fresh samples, current context and a new explicit review.

**When** samples are sent, cancelled before sending, superseded or disposed,
**then** clear sample text is kept out of SQL, queues, Blob evidence, application
logs, telemetry and browser persistent storage. Clearing the in-memory sample
flow does not claim zero upstream provider retention. M6 separately verifies
deployed HTTP/proxy/APM capture settings; source-only tests cannot prove them.

**Verify:** M2 pending/unknown/reopen fixtures; M4 transport-loss/deadline/disposal
and non-replay tests; M5/M6 artifact and deployed capture checks. Grounding: R11.

## Cross-cutting scenarios

### UX-28 — Enforce the existing role boundary

**Given** each of the four control-plane roles, **when** navigation and direct
routes/API calls are exercised, **then** permissions follow this matrix. A hidden
button is not authorization; the API must independently reject disallowed calls.
Multiple assigned roles receive their union of permitted actions, still subject
to tenant, actor and operation ownership checks.

| Action/data | Administrator | Operator | Auditor | Support reader |
|---|---|---|---|---|
| Agent list/details, capability read, protection operation read by ID | Yes | Yes | Yes | Yes |
| Provisioning operation/history; Purview connection, collection and profile summaries; enable/disable | Yes | Yes | No | No |
| Audit events | Yes | No | Yes | No |
| Registration, blueprint inventory, credential metadata/issue/revoke, delete/retry, feature/system settings | Yes | No | No | No |
| Delegated Registry action; classifier inventory; protection review/confirmation/mutation; runtime sample review/execute/status | Yes | No | No | No |

**Given** an external agent, **then** its ingress key and exact registration
binding authorize only the corresponding external-agent API surface, never
administration. A user with no recognized role sees a safe access-denied state.
Expired sign-in preserves a safe return destination without including credentials
or samples. The portal Reader mapping means SupportReader, not Auditor.

**Verify:** M2 representative restricted fixtures; M3/M4 each matrix cell in
real component/API tests; M6 actual assigned identities. Grounding: R1.

### UX-29 — Distinguish empty, loading, stale and error states

**Given** every asynchronous list, registration, operation and protection task,
**when** requests are pending, empty, denied or failed, **then** loading has a
named busy state; empty explains the next permitted action; access denied does
not masquerade as empty; and a safe error exposes an opaque support reference
without dependency bodies. A failed refresh may show old data only as stale.

**When** retrying a read, **then** only the intended read repeats. Mutation
responses with unknown outcomes provide reconciliation rather than the same
generic retry action. No state briefly flashes a success/empty claim while still
loading, and unrelated input is preserved where it is safe to keep it.

**Verify:** M2 fixture transitions; M3/M4 production components with finite
scripted transports. Grounding: R3, R6, R9, R11.

### UX-30 — Complete the flow by keyboard with understandable focus

**Given** a keyboard-only user, **when** they traverse navigation, registration,
key handoff, paging, policy editing and sample confirmation, **then** all actions
are reachable by logical Tab order with visible focus and meaningful names.
Field errors are associated with their inputs; counts/status changes and copy
feedback are announced without exposing secrets. Status is not conveyed by color
alone. Links and buttons retain their distinct navigation/action meanings.

**When** a confirmation opens, **then** its title and consequence are available
to assistive technology, focus moves into it and stays within it; closing an
unsubmitted review with Cancel/Escape restores focus to the invoker. Busy
execution cannot be dismissed in a way that implies cancellation/rollback.
Browser accessibility-tree inspection complements keyboard checks; the prototype
alone is not a screen-reader or formal accessibility-conformance certification.

**Verify:** M2 Chrome keyboard/accessibility inspection; M3/M4 real rendered
components, validation, dialog and status checks. Grounding: R9, R12.

### UX-31 — Keep narrow layouts usable

**Given** 360 CSS-pixel width and separately 200% browser zoom,
**when** every designed journey and confirmation is opened,
**then** primary actions, errors, review consequences and selected values remain
visible without overlapping or clipped controls. Long IDs/endpoints wrap or use
an explicitly accessible copy/scroll region; they do not expand the whole page.
Agent tables provide a readable narrow presentation with preserved labels and
actions. No confirmation requires inaccessible horizontal scrolling.

**Verify:** M2 Chrome fixtures; M3/M4 the actual responsive application, including
long names, long IDs, large classifier selections and validation messages.
Grounding: R9, R12.

### UX-32 — Keep integration instructions safe and telemetry claims precise

**Given** the external developer's handoff, **when** they copy the sample command,
**then** it identifies the verified endpoint/external ID and prompts separately
for the key without echoing it. It uses synthetic text and explains required
tenant-user context for Agent 365 paths. Missing/wrong identity fails rather than
inventing an actor or copying one from another registration.

**Given** interaction HTTP 202 or an export attempt, **when** the result is
displayed, **then** acceptance, processing and destination-specific outcomes are
distinct. The sample checks the receipt's status/processing fields and does not
report a Failed processing result as successful ingestion merely because HTTP
202 was returned. The sample now validates matching acceptance receipts and their
recognized status/processing fields. Agent 365 and Azure Monitor settings/results remain independent. A
recorded Azure Monitor span is not claimed to be confirmed downstream delivery;
unsupported/unrouted/rejected results cannot be relabeled as delivered.

**Verify:** M2 handoff/result copy; M3/M4 sample/ingestion/export fixtures; M6
actual attribution and destination receipt/delivery observations. Grounding: R5,
R6, R7.

### UX-33 — Hand off from local installation to the verified portal

**Given** an installation operator using the temporary local Setup application,
**when** they review the target, **then** the page shows the current account,
tenant, subscription name and ID, region and project identity. This installer
identity is not the deployed application's Operator role. Its local Install
Gateway pages remain distinct from the deployed portal's Getting started route.

**Given** a plan bound to the reviewed source, target and configuration,
**when** any bound input changes, **then** deployment is unavailable until a new
matching plan is prepared and reviewed. Feature/cost/authority acknowledgements
are retained with their actual scope. No old checkpoint stands in for a current
plan, and deliberately deleted resources are not presented as a resumable run.

**When** work runs or is interrupted, **then** the page distinguishes deployment,
verification and required action, names the stage and uses recorded state for
any eligible continuation. Unknown provider outcomes require exact readback;
there is no blind repeat-create action or claim that closing the browser undoes
work already dispatched.

**When** the canonical run returns a successful, validated endpoint result,
**then** Open Getting started uses that exact verified Admin UI endpoint and
shows the corresponding API endpoint. Missing/invalid/ambiguous endpoint results
keep the user on progress; no guessed URL is enabled. Deployment verification
does not claim an Active registration, open registration admission, effective
protection or supported production use of the preview Registry dependency.

**Verify:** M2 installer fixture and portal transition; M3.1 wording/navigation;
M5 setup source/candidate contract tests; M6 actual installation and endpoint
readbacks. Grounding: R13.

### UX-34 — Complete the novice protection journey

**Given** an administrator who has no external instructions,
**when** a protection operation is pending, complete, stopped, failed, unknown or
expired, **then** its first useful content answers **What happened**, **Why this
matters**, **What remains**, and **Next step**. The technical log is secondary,
initially collapsed under **Technical operation details**, with descriptive step
labels. **Skipped means not run, not passed**; the explanation identifies why the
step was skipped and any separate task still required. A Completed configuration
operation alone never becomes a current enforcing badge.

**Given** accepted companion completion, **when** independent verification is
pending, **then** the heading is **Checking the Purview connection**. Only the
retained original operation is observed by GET every three seconds for at most
five minutes. No confirmation, companion resubmission or new connection is
dispatched by observation. **Stop automatic updates** pauses only observation,
without cancelling accepted work or marking it Failed. On a manual stop or at
the bound, offer **Resume automatic updates** for the same operation within a
fresh bounded session. Keyboard focus remains on the corresponding control.
A manual status check does not restart stopped automatic updates. Terminal
readback separately reloads current readiness/inventory context; an expired
current snapshot remains expired even when the operation reports Completed.
Leaving, reopening and failed/unknown reads preserve the original recovery
identity and never provide a blind create retry.

**Given** a current completed connection, **then** the heading is **Purview
connection verified**. Explain independent Gateway app-access verification and a
current classifier inventory, why these are needed for policy review, and that
no policy was created, no per-agent protection was enabled, and DLP blocking was
not tested. **Continue to shared policies** requires an explicit user action.
Completion does not automatically navigate, review, configure or enable anything.
Show the actual validated inventory count and freshness, not a single-SIT
selector. A malformed/mismatched response must not yield a trusted count. The
optional collection selector remains independent.

**Given** a completed connection whose readiness expires, **then** use
**Connection verified earlier; refresh required**, preserve the historical
Completed outcome, and offer a fresh **Review connection refresh** only when
permitted. The old command, deadline and evidence remain invalid and are not
rerun. A failed operation stays Failed after its old expiry. Awaiting Windows
input retains UX-18's six trust/paste steps, expected actor and explicit UTC
expiry; unknown/pending work does not expose stale completion controls.

**When** the administrator continues to policy, **then** they choose a blueprint
shared by the intended agents and review the exact profile, blueprint identity,
classifier IDs, per-classifier thresholds, mode and shared impact. Separate
review, confirmation and current saved-profile readback remain visible. Saved
Enforce uses **Policy saved; behavior is not verified** with **Continue to
behavior tests**. Both `/settings/policy?profile={id}` and
`/settings/runtime?profile={id}` preserve that exact context; an unavailable ID
never selects the first or another arbitrary profile. Missing roles or
prerequisites name the limit and provide a safe permitted alternative, not an
unusable action or silent downgrade.

The header presents four ordered steps, **Connect tenant**, **Set shared
policy**, **Test behavior**, **Review agent choices**; its current-location
highlight is not a passed-state badge. Separate overview/collection/defaults
tools from this sequence. Place the editor before the saved-policy disclosure,
avoid a duplicate locked blueprint selector, and move focus back to that editor
when **Review settings** is activated. Select SITs once, then configure their
thresholds. Newly selected types start at 1 / Any (-1) / 75 / 100 with explanations
and normal validation. Saved values, edited deselected/reselected types and
unknown legacy values must not be overwritten by those defaults.

**Given** an expired prerequisite while editing, **then** the separate-tab
connection path and explicit prerequisite reload preserve the unsaved name,
mode, selections and thresholds. They do not extend authority or auto-submit a
review. **Given** a saved operation's expiry/timeout/read-unavailable failure,
**then** explain that partial effects are possible and first recover current
prerequisites. **Review existing policy check** reviews read-only reconciliation
of the exact saved profile, never a replacement create. A newly confirmed
reconciliation can bind unchanged selections to a genuinely current inventory,
preserving provider/profile identity, settings and agent choices while clearing
prior runtime certification. Review alone changes no binding. Test transaction
rollback, one-outbox replay, four modes, missing/renamed types, legacy unknown
thresholds, expiry equality and context changes after confirmation. A mismatched
profile/operation link must not direct a check at the other profile.

**Given** an active page request or bounded observation, **then** visible subtle
activity feedback and meaningful text explain what is being awaited. Do not
invent provider progress, percentages or finish times. Verify active, paused,
failed-read and expired states, last-check/saved-step context, reduced-motion
fallback and no live-region clock spam. Stopping observation does not cancel
server work or enable a replay.

**When** the administrator opens that runtime task, **then** the page guides them
to approve a clean negative control and intended-SIT examples for every selected
classifier. The exact saved mode, thresholds, profile/revision, execution identity
and effective scope are reviewed before a single explicitly approved execution.
Raw samples remain private and ephemeral under UX-25/27; errors and unknown
results use same-operation metadata readback, never automatic replay.
The current saved profile, effective scope, connection/inventory and unexpired
applicable evidence determine readiness, not the historical receipt alone.
Matched-classifier attribution is not invented.

**Given** current applicable Enforce verification, **when** the user selects
**Continue to agents**, **then** they choose an agent using that blueprint and
explicitly review/save its protection choices. Previous connection, policy and
test steps did not change agent feature choices. The per-agent action preserves
independent Prompt Shields choices and does not edit siblings or shared policy.

**Given** saved Off, **then** it is a valid completed choice with no runtime test
requirement and no sample submission. Simulation remains non-blocking, with
optional diagnostics rather than required enforcement certification. Both paths
can continue to explicit agent choices without manufacturing a block proof.
Collection is optional and separate, never a prerequisite to DLP; none of these
steps claims downstream telemetry delivery.

**Verify:** M2 synthetic Chrome follows the actual links/buttons from connection
through policy review, approved runtime result and explicit agent choice,
including a non-first profile, missing profiles, Off/simulation, recovery,
three-second/five-minute local observation, explicit Stop/Resume, terminal
current-context reload, keyboard-only use, 360/390-pixel
layouts and actual 200% browser zoom. Its local timers and fake readbacks are not
HTTP/provider or durable-recovery evidence. M4 verifies the real components,
GET/mutation boundaries, current-state/expiry updates, role restrictions and
exact-profile navigation. M6 separately establishes hosted authorization and
provider behavior. Grounding: R1, R7–12. No design fixture or old pass count closes
the milestone implementation or hosted acceptance.

## Source and existing-test grounding

These references explain the behavior to preserve or the known limitation to
correct. Referencing an existing test does not claim it covers the whole future
scenario. Add focused production tests for gaps during M3/M4, including complete
role enforcement, companion/deferred-policy and runtime unknown-outcome flows.

| Ref | Retained source and relevant baseline tests |
|---|---|
| R1 | [API policies](../../src/Gateway.Api/Authorization/AuthorizationPolicies.cs), [agent routes](../../src/Gateway.Api/Controllers/AgentsController.cs), [operation routes](../../src/Gateway.Api/Controllers/OperationsController.cs), [system routes](../../src/Gateway.Api/Controllers/SystemController.cs), [protection routes](../../src/Gateway.Api/Controllers/ProtectionController.cs), [runtime routes](../../src/Gateway.Api/Controllers/PurviewRuntimeTestsController.cs), [portal role mapping](../../src/Gateway.AdminUi/Authentication/PortalRoleClaimsTransformation.cs). |
| R2 | [Register handler](../../src/Gateway.Application/Agents/Commands/RegisterAgentHandler.cs), [validator](../../src/Gateway.Application/Agents/Validators/RegisterAgentValidator.cs), [registration page](../../src/Gateway.AdminUi/Components/Pages/RegisterAgent.razor), [validation tests](../../tests/Gateway.UnitTests/RegistrationValidationTests.cs), [transaction/default/catalog tests](../../tests/Gateway.IntegrationTests/RegistrationTests.cs). |
| R3 | [List handler](../../src/Gateway.Application/Agents/Queries/ListAgentsHandler.cs), [repository cursor/search](../../src/Gateway.Infrastructure/Persistence/Repositories/AgentRegistrationRepository.cs), [agents page](../../src/Gateway.AdminUi/Components/Pages/Agents.razor), [overview](../../src/Gateway.AdminUi/Components/Pages/Home.razor), [list-state tests](../../tests/Gateway.AdminUi.Tests/Components/AgentsPageBaselineTests.cs), [SQL listing tests](../../tests/Gateway.IntegrationTests/AgentListingTests.cs), [listing journeys](../../tests/Gateway.AdminUi.Tests/Components/AgentListingJourneyTests.cs). |
| R4 | [Credential lifecycle tests](../../tests/Gateway.IntegrationTests/CredentialLifecycleTests.cs), [issue handler](../../src/Gateway.Application/Agents/Commands/IssueAgentIngressCredentialHandler.cs), [revoke handler](../../src/Gateway.Application/Agents/Commands/RevokeAgentIngressCredentialHandler.cs), [registration transaction tests](../../tests/Gateway.IntegrationTests/RegistrationTests.cs). |
| R5 | [Sample gate](../../src/ExternalAgent.Sample/SampleInteractionRunner.cs), [receipt/context tests](../../tests/Gateway.UnitTests/PromptReceiptTests.cs), [SQL prompt workflow](../../tests/Gateway.IntegrationTests/PromptWorkflowTests.cs), [SQL receipt races](../../tests/Gateway.IntegrationTests/ConcurrentReceiptTests.cs), [protection-context invalidation](../../tests/Gateway.IntegrationTests/ProtectionReadinessTests.cs). |
| R6 | [Delegated completion handler](../../src/Gateway.Application/Agents/Commands/CompleteAgent365RegistrationHandler.cs), [delegated provider baseline](../../tests/Gateway.ObservabilityRuntime.Tests/Providers/DelegatedRegistryBaselineTests.cs), [worker recovery baseline](../../tests/Gateway.ObservabilityRuntime.Tests/Worker/WorkerRecoveryBaselineTests.cs), [provisioning worker](../../src/Gateway.Provisioning.Worker/ProvisioningMessageHandler.cs), [operation page](../../src/Gateway.AdminUi/Components/Pages/OperationStatus.razor). |
| R7 | [Effective-feature evaluator](../../src/Gateway.Application/Protection/ProtectionEffectiveFeatureEvaluator.cs), [readiness-state tests](../../tests/Gateway.UnitTests/ProtectionStateTests.cs), [installed-binding/shared-policy tests](../../tests/Gateway.IntegrationTests/ProtectionReadinessTests.cs), [destination baseline](../../tests/Gateway.AdminUi.Tests/Components/AgentsPageBaselineTests.cs). |
| R8 | [Companion launch contract](../../src/Gateway.Application/Protection/PurviewCompanionLaunchContract.cs), [Windows companion](../../src/Gateway.Purview/Automation/Connect-PurviewTenant.ps1), [connection completion bindings](../../src/Gateway.Application/Protection/ProtectionMutationHandler.cs), [inventory/tenant rules](../../src/Gateway.Application/Protection/ProtectionAdministrationRules.cs). |
| R9 | [Getting started](../../src/Gateway.AdminUi/Components/Pages/SetupCenter.razor), [details](../../src/Gateway.AdminUi/Components/Pages/AgentDetails.razor), [Settings](../../src/Gateway.AdminUi/Components/Pages/Settings.razor), [loading](../../src/Gateway.AdminUi/Components/Shared/LoadingState.razor), [errors](../../src/Gateway.AdminUi/Components/Shared/ErrorState.razor), [empty states](../../src/Gateway.AdminUi/Components/Shared/EmptyState.razor). |
| R10 | [Review](../../src/Gateway.Application/Protection/ProtectionReviewHandler.cs), [confirmation token binding/expiry](../../src/Gateway.Application/Protection/ProtectionOperationTokenService.cs), [mutation/concurrency](../../src/Gateway.Application/Protection/ProtectionMutationHandler.cs), [threshold/selection rules](../../src/Gateway.Application/Protection/ProtectionAdministrationRules.cs), [registration intent](../../src/Gateway.Application/Protection/AgentPurviewConfigurationService.cs), [deferred continuation](../../src/Gateway.Application/Protection/ResolveDeferredPurviewConfigurationCommand.cs). |
| R11 | [Runtime panel baseline](../../tests/Gateway.AdminUi.Tests/Components/ProtectionReviewBaselineTests.cs), [runtime service](../../src/Gateway.Application/Protection/PurviewRuntimeTestService.cs), [runtime validation](../../src/Gateway.Application/Protection/PurviewRuntimeTestValidation.cs), [limits and context](../../src/Gateway.Domain/Models/PurviewRuntimeTestModels.cs), [browser sample lifecycle](../../src/Gateway.AdminUi/wwwroot/purview-runtime-test.js), [runtime report](../../src/Gateway.AdminUi/Components/Shared/PurviewRuntimeTestReport.razor). |
| R12 | [Confirmation component](../../src/Gateway.AdminUi/Components/Shared/ConfirmPanel.razor), [focus handling](../../src/Gateway.AdminUi/wwwroot/confirm-panel.js), [copy handling](../../src/Gateway.AdminUi/wwwroot/copy-text.js), [styles](../../src/Gateway.AdminUi/wwwroot/app.css). |
| R13 | [Setup wizard state](../../tools/Gateway.Setup/Services/SetupWizardState.cs), [plan preparation](../../tools/Gateway.Setup/Services/BootstrapPlanPreparationCoordinator.cs), [execution/endpoint admission](../../tools/Gateway.Setup/Services/BootstrapExecutionCoordinator.cs), [verified handoff](../../tools/Gateway.Setup/Components/Pages/Finish.razor), [target/state tests](../../tests/Gateway.Setup.Tests/Services/SetupWizardStateTests.cs), [plan tests](../../tests/Gateway.Setup.Tests/Services/BootstrapPlanPreparationCoordinatorTests.cs), [execution tests](../../tests/Gateway.Setup.Tests/Services/BootstrapExecutionCoordinatorTests.cs). |

The production API schema remains [OpenAPI](../api/openapi.yaml). The final
screen copy and scenario-linked browser fixtures are described in
[screen design](screen-design.md), with role journeys and terminology in
[journeys and shared language](journeys-and-language.md). Only the milestone checklist records which
design, implementation and verification conditions have actually been met.
