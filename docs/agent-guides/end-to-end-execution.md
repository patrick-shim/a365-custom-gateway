# End-to-end execution contract

This is the shared operating contract for every model, coordinator, delegate,
reviewer, skill and handoff in this repository. Read it after the required
`AGENTS.md` sequence and before taking task actions. It supplements safety and
provider constraints; it grants no cloud authority and bypasses no consent.

## One durable objective

For an end-to-end request, deliver the working product from bootstrap through
Azure deployment and independent live acceptance. Source, tests, review, packaging,
deployment process exit and platform Running are milestones, not the outcome.
Do not reinterpret the request as source-only because execution becomes difficult.

The Full evaluation objective includes a clean UI-driven installation and full
live acceptance, not merely a recovered deployment. The current operator-selected
recipe and authority live in the continuation checkpoint and local execution
context. An explicitly revised clean-test instruction can supersede an earlier
recovery-first plan; do not keep enforcing obsolete ordering. Required live
evidence includes:

- public Windows bootstrap and all nineteen stages plus `gateway verify`;
- actual Windows executor startup, runtime/package identity and provider execution;
- deployed Admin UI sign-in, primary routes, desktop/narrow views and role denials;
- two compatible blueprints as authorized, one registration each with distinct
  child identities, user-only delegated Registry completion and verified Active;
- independent Agent 365 activity/audit landing with correct identity attribution;
- per-registration Prompt Shields allow/block and single-use receipt isolation;
- Settings-owned SIT selection, fixed KYD Group and blueprint Individual DLP;
- exact DLP capability, policy, propagation, token-role and runtime allow/block proof;
- operational health, private connectivity, immutable artifacts and safe lifecycle
  evidence, followed by reviewed durable release evidence.

For the clean-test recipe: inventory and bind the authorized deletion scope,
tear it down and independently verify removal, run the Windows Setup UI to
configure and deploy, then run the live matrix and gather safe screenshot proof.
Diagnose and correct failures before repeating the affected cycle. Once successful,
repeat teardown, UI installation and live acceptance from scratch with the agreed
edge cases. Each attempt gets fresh deployment identity/state; retained accepted
state is evidence and must never be reset to simulate a fresh install. Do not
blindly loop ambiguous create/delete calls, repeat unchanged failures indefinitely,
or delete unrelated resources merely because they share the tenant.

Capture screenshots only after secrets/content-bearing panels have been cleared
or hidden before capture. Never capture login passwords, one-time Gateway keys,
tokens, prompts/responses, provider bodies or certificate material. Store safe
screenshots with attempt, test, target-reference and timestamp in local evidence;
a screenshot of configuration is not independent provider proof.

Optional product features remain optional for ordinary bootstrap and registration.
When selected in the user's acceptance scope, their live tests are required for
that delivery. Do not confuse core bootstrap completion with Full evaluation
completion. Mock E2E tests never replace this matrix.

## Automatic execution, bounded permissions

Proceed through authorized work without another planning cycle or routine
reapproval. Investigate failures, make coherent fixes, run the affected validation,
and continue. Preserve the current approved dependency order, including immutable
source generation boundaries. Do not substitute a replacement target for recovery
without an explicit scope change. Record an operator-authorized change of approach
as a Decision and synchronize the checkpoints instead of silently changing scope.

Pause only the affected action at a genuine missing permission, unavailable
external access, policy restriction, or unavoidable interactive sign-in/consent.
Continue independent authorized work if the user has not stopped it. Do not ask
the user to debug ordinary tool failures or repeat a supplied implementation plan.
Automation does not substitute app-only identity for required delegated actions,
bypass MFA, waive consent, or authorize spending or destructive operations.

When a live failure exposes a cross-module gap, reproduce it through the real
dispatcher, source/identity guards and caller composition; mock only the external
network/process boundary for that regression. Mocking the shared adapter or guard
can hide incorrect ARM/Graph routing or rejected permissions while a full suite
passes. Keep those guards intact, capture the safe failure signature, and require
the corrected real-boundary regression before another deployment attempt.

## Intent, authorization and credentials are separate

Maintain a bounded **execution context** in ignored/access-controlled local
operator storage and reference it from ledger Evidence and the continuation
checkpoint. It is coordination metadata, not an accepted bootstrap plan, a
provider receipt, or a credential store. Preserve these fields across handoffs:

| Field | Required content |
|---|---|
| Product objective | Full outcome; unchanged by subtask/test results |
| Acceptance scope | Required matrix and explicit user-approved exclusions |
| Current work | Phase, gate, exact next executable action, owner and dependencies |
| Authority | Exact target reference, allowed operations, exclusions, approval reference, status and expiry if supplied |
| Holds | Later stop/denial, affected scope, precedence and resolution reference |
| Credential availability | User-supplied fact, secure-input mechanism reference, last safe availability result, expiry if known |
| Evidence | Source/plan/artifact binding, timestamps, actual test/review/live references and unverified checks |
| Disposition | InProgress, Blocked, Paused, Cancelled or Delivered, separately for subtask and product |

Never include credential values, tokens, assertions, keys, certificate/PFX material,
authorization headers, prompts/responses or raw provider bodies. Exact tenant and
resource identifiers stay in the local operator record, not tracked instructions.
Persist only a reference to the documented non-echoing credential-input mechanism.
If that reference is unknown, record Unknown; do not guess or search private files.

Remember that the user supplied credentials even after context loss. That fact
does not prove current validity or grant every action. Reuse only through the
documented secure mechanism when authorized; never read or echo private values
to check availability. Request renewed access only after a safe check establishes
missing/expired access or a genuinely required interactive step. Clearly distinguish
Provided, Unverified, Available and Expired/Unavailable rather than conflating them.

Existing exact-target authority survives compaction, model changes and delegated
work within the same authorized operator session, subject to later holds, expiry
and changed scope. Do not repeatedly request the same still-valid approval.
Git alone supplies neither authority nor credentials on another machine/session.
A broader objective or a generic "continue" reminder does not cancel an explicit
cloud prohibition. A changed target, mutation class, spending/policy/cleanup scope,
or acceptance fingerprint requires the appropriate new approval.

## Failed prompts and explicit stops

An approval tool returning "user unavailable", timeout or transport failure means
**NoResponse**. It is not a denial, revocation, missing credentials, or consent.
Preserve existing authorization and credential facts. Try a permitted alternative
communication route with the exact bounded request; if none is available, persist
the unresolved boundary without claiming the user was absent. NoResponse itself
never authorizes a previously prohibited action.

An explicit stop pauses the requested execution immediately. Stop launching work;
contain only this session's owned running processes if necessary and permitted.
Do not cancel another owner's work or destroy evidence. A side discussion,
complaint, progress request or automated completion reminder does not restart
paused execution. Resume only the scope explicitly resumed by the user. A request
to repair operating instructions authorizes that repair, not cloud execution.

## Continuation and delegation

On restart read the current tracked checkpoint, validated local ledger and referenced
execution context. Reconcile them with latest explicit user instructions before
acting. Record the current HEAD and document fingerprints; an old session-start
source binding is not the current candidate. Do not mine chat history or old
journal shards to invent current authority or reconstruct the objective.

Use `objective` for the product, `workItem` for the current bounded assignment,
`summary` for results, `blockers` for holds, and `nextAction` for the exact unfinished
action. Routine results must not overwrite the objective, erase holds, or reset a
gate. Correct objective drift with a coordinator Decision and a user-scope or
correction evidence reference. Preserve the old/new objectives in that event.

Each assignment and structured handoff carries the product-objective reference,
bounded task, owner/file boundary, starting checkpoint, validation and stopping
condition, current authorization/credential-reference/hold context, actual evidence,
and next action. A reviewer completing an assignment does not finish delivery.
The coordinator receipts the handoff and continues without making the user relay it.
Read-only delegates do not obtain mutation authority from this protocol.

## Completion and reporting

The seven gates remain exactly Plan, Build, OfflineValidate, Deploy, LiveValidate,
UpdateCheckpoint and Complete. Follow their evidence and invalidation rules in
the [release gate](../../.agents/skills/a365-bootstrap-delivery/references/release-gate.md).
Do not invent a Passed gate from configuration, a test substitute or stale evidence.

Report subtask and product separately: **"Protocol repair verified; product delivery
Paused, deployment/live acceptance outstanding"** is truthful. **"End-to-end
complete: 50 tests passed"** is not. A blocked live action does not excuse unfinished
authorized offline work. Persist an actual failed command/check or exact authority
gap, work still possible, and the next action instead of a status-only success.

Use delivery `Complete` only after every required gate and live matrix row has
current bound evidence, all assignments/blockers are resolved, checkpoints and
release evidence are current, and independent final review has passed. A stop,
blocked approval, end of a chat or platform demand to call a completion tool does
not satisfy this contract. If the host forces turn closure, explicitly label it
Paused/Blocked/Cancelled and leave the product ledger open. Never use the tool
name as evidence that delivery is complete.

The recorder checks completion reference structure, not provider truth. Supply one
`Gate=reference` for each of Plan, Build, OfflineValidate, Deploy, LiveValidate,
UpdateCheckpoint and IndependentReview. The coordinator/reviewer must inspect
those actual receipts for source/target/time binding and matrix coverage; fabricated
or placeholder references are never production evidence.

## Coverage and limits

`AGENTS.md`, model instructions, both role catalogs, canonical skills, skill adapters
and prompt descriptors must explicitly inherit this contract. Workstream guides and
runbooks inherit it without expanding their specific action boundaries. Run the
existing ledger self-tests and `OperatingContract.Tests.ps1` after changes.
These guards make the agreement recoverable and test instruction wiring; they
cannot guarantee arbitrary future model behavior or configure global host reminders.
