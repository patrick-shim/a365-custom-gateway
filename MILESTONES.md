# Project milestones

This checklist is the sole completion and acceptance record for this project.
The retained application is the working baseline. Work improves its user journeys,
wording, selected features, and reproducible validation.

## Working agreement

- Azure tenant: `ff8b1e46-ff0f-4bc2-ab02-caf2b92da496`.
- All project Azure resources belong in **internal-security-lab-02**, subscription
  `6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`.
- Use the temporary administrator credential already supplied in this conversation,
  or its authenticated session. Do not request the credential again. Do not copy
  the password into source, documents, logs, commands, or repository memory.
- Use installed **Chrome or Edge** for browser work. The user authorized direct
  browser control on 2026-09-19; the extension is optional. Synthetic local checks
  use an isolated profile rather than an authenticated user session.
- The user deliberately deleted supporting files and related Azure resources.
  Historical deployment checkpoints do not describe a current deployment.
- Development proceeds through the milestones below. No prior test total,
  source review, deployment receipt, or chat statement marks a task complete.

## Checkbox rules

1. `[ ]` means the stated acceptance condition has not been demonstrated.
2. `[x]` means the work and its stated verification both passed. Add a short,
   non-secret verification note and date on that same checklist item. The item
   itself remains the evidence; do not create a competing evidence ledger.
3. A blocked or partially completed task remains unchecked. Describe its next
   action on the same item; never use a checkmark for an attempt.
4. A milestone closes only when every task, including its final whole-project
   documentation/state synchronization and consistency review, is checked.
5. When later work invalidates an acceptance condition, reopen that task and its
   dependent milestone closure. Remove conflicting completion claims elsewhere.
6. Runtime checkpoints and receipts required by the application remain operational
   data. They are not a second project-completion record.
7. Before each closure, review every authored Markdown document and relevant
   configuration/schema, directive, state and memory file. Update changed facts;
   verify unchanged facts. Guides describe behavior and link here for completion.

## M0 — Working agreement, access and synchronized plan

- [x] **M0.1** Verify the supplied administrator session and the exact tenant/name/ID
  of the selected Azure subscription using read-only access. Verified 2026-09-16:
  Azure CLI account metadata matched the supplied administrator and pinned tenant/
  subscription; an explicitly scoped live resource-group read succeeded.
- [x] **M0.2** Establish Chrome as the browser used for this task and persist that
  preference in the project directives and memory. Verified 2026-09-16: the Chrome
  extension opened the tenant sign-in page; AGENTS.md and MEMORY.md specify Chrome.
- [x] **M0.3** Publish actionable milestone tasks with explicit implementation and
  verification conditions; make this file the only acceptance checklist. Verified
  2026-09-16: M0-M6 each name observable acceptance and a final full synchronization.
- [x] **M0.4** Establish project agent directives, a continuation state document,
  and repository memory that preserve the working-baseline assumption and user
  instructions without storing the temporary password. Verified 2026-09-16:
  AGENTS.md, docs/project-state.md and MEMORY.md created with non-secret context.
- [x] **M0.5** Reconcile all existing project documentation with the retained code:
  remove obsolete active-deployment claims and dangling guide links; document the
  deleted tooling/test prerequisites; align API documentation with implemented
  protection configuration and runtime testing. Verified 2026-09-16: all 18
  Markdown documents reconciled; API/OpenAPI updated for reviewed/deferred policy
  configuration, multi-SIT modes/thresholds and approved runtime samples. Historical
  claims and deleted prerequisites are explicit; independent consistency review
  found no remaining actionable issues.
- [x] **M0.6** Complete the whole-project documentation/state synchronization,
  validate local documentation links and OpenAPI references, inspect the complete
  diff, and verify that no application behavior or Azure resources changed.
  Verified 2026-09-16: 119 local links and one anchor resolve; duplicate-key-safe
  OpenAPI parsing passes with 425 resolved references and 48 unique operations;
  reviewed runtime DTO/schema properties agree. Documentation diff/whitespace and
  independent whole-project consistency checks pass. Only documentation changed;
  Azure access was read-only. No application build or runtime test is claimed.

## M1 — Reproducible source and behavioral baseline

- [x] **M1.1** Complete the remaining file-by-file source review and record the
  current journeys and invariants in the existing product/architecture guides.
  Verified 2026-09-16: remaining bootstrap, maintenance, executor/recovery and
  operational-wrapper files read through EOF, including initially truncated
  ranges. Existing architecture/API/bootstrap/operator guides now distinguish
  current journeys, immutable recovery boundaries, short-lived readiness,
  telemetry/list/ingestion limits and portable versus historical-artifact tests.
  Local guide-link and OpenAPI reference/route/scope checks pass; no provider
  execution was used as source-review evidence.
- [x] **M1.2** Establish a complete source baseline including untracked authored
  files and required build inputs, excluding generated output from source delivery.
  Verified 2026-09-16: 849 tracked/untracked authored files copied into a new clean
  tree; required VERSION/tool sources restored, 27 project references resolve.
  Copy/end-of-run hash checks passed; bin/obj, Git and operational state excluded.
- [x] **M1.3** Re-establish the minimum missing Setup, migration, verification and
  test tooling needed by the retained projects; validate their references and
  entry points without relying on historical environment artifacts.
  Verified 2026-09-16: restored 44 Setup and 23 migration/verification/helper
  sources from b760553 and source checkpoint 137c6cf, with bounded current-contract
  adaptations. Clean-run Setup 314 and tooling 65 tests passed; root launcher
  help, native help/local validation and manifest-v2 admission passed without
  provider calls. Full migration/deployment acceptance remains M5/M6.
- [x] **M1.4** Build the retained solution from a clean source copy with the pinned
  toolchain and identify reproducible local test commands.
  Verified 2026-09-16: Test-LocalBaseline.ps1 -IncludeSql built all 27 projects in
  Release from the clean source with SDK 10.0.401 (10.0.400 latestPatch policy),
  zero warnings/errors. PowerShell 7.6.6 parsed 59 sources; local commands are in
  README. No old binaries, configuration or deployment checkpoints were used.
  Repeated after SQL traits settled: current source/hash checks and owned
  workspace cleanup passed with the same clean build and test outcomes.
- [x] **M1.5** Add baseline tests for registration, credential lifecycle, prompt
  receipts, protection states and worker recovery; record actual passing outcomes.
  Verified 2026-09-16: clean-run .NET results were Source 27, Unit 90, SQL 64,
  worker/provider 60, Admin UI 22, Setup 314 and tooling 65: 642 passed with
  zero failed/skipped. Pester 25, portable packaging, abort 106 and policy-metadata
  30 checks passed. Known later-milestone defects are not claimed fixed.
- [x] **M1.6** Establish deterministic UI/provider fixtures and a real SQL test
  path for transactional behavior; prove the local suite cannot call live providers.
  Verified 2026-09-16: actual adapters use finite terminal HTTP/token fixtures,
  UI/process/provider guards reject unplanned calls and ambient authentication.
  All 64 SQL tests ran on uniquely owned LocalDB instances/databases with exact
  local pipe binding, real locks/rollback/receipt races and verified cleanup.
  Default runner excludes SQL; IncludeSql and nonempty/all-passed result guards
  are tested. No live-provider, browser, full migration or OS-firewall claim.
  Final clean rerun executed all 64 Category=SqlServer cases; no selector mismatch.
- [x] **M1.7** Synchronize all project documents, directives, continuation state,
  memory and applicable configuration contracts; pass a fresh consistency review.
  Verified 2026-09-16: all 22 authored Markdown documents reviewed; 147 local links
  and 3 heading anchors resolve. Source/API checks pass for project/build inputs,
  configuration, 425 OpenAPI references, unique operations, actual server-relative
  routes and distinct OAuth scope/role requirements. Directives/memory preserve
  offline fixtures and owned LocalDB guidance; complete diff/whitespace reviewed.
  Final clean rerun passed after SQL selector alignment; temporary workspaces
  removed. At M1 closure, M2 had not started; no Azure deployment was claimed.

## M2 — User journeys, language and acceptance design

- [x] **M2.1** Define administrator, operator, auditor, support-reader and external
  developer journeys with entry point, decisions, outcomes and recovery actions.
  Verified 2026-09-19: docs/ux/journeys-and-language.md defines all five personas
  plus the separate local installation operator; role permissions map to current
  API policies/controllers and each journey names decisions, outcomes and recovery.
- [x] **M2.2** Define shared wording for installed, configured, active, off,
  simulation, verifying, enforcing, unavailable and action-required states.
  Verified 2026-09-19: the shared glossary separates saved choices, capability,
  registration and live evidence; includes precedence, expiry/unknown outcomes,
  exact recovery copy and accepted/processed/delivered distinctions. Compared with
  current role, readiness and receipt contracts; no production wording change claimed.
- [x] **M2.3** Produce reviewable screen layouts and exact copy for onboarding,
  registration, credential handoff, operations and protection tasks.
  Verified 2026-09-19: docs/ux/screen-design.md specifies layouts, copy and recovery;
  the local HTML/CSS/JavaScript prototype provides 14 views with synthetic fixtures.
  Independent static review resolved role, selected-agent/key state, shared-policy
  scope/mode/threshold and recovery contradictions. JavaScript syntax and 350
  role/state/view render combinations pass; the allowlisted loopback server serves
  only its three assets and rejects unrelated paths/writes. No browser result claimed.
- [x] **M2.4** Exercise the proposed flow in Chrome with representative empty,
  loading, success, error and restricted-role fixtures, keyboard navigation and
  narrow layouts; resolve the identified usability issues.
  Verified 2026-09-19: installed Chrome 153.0.8010.48 passed 1,504 local fixture
  checks, including 1,050 view/persona/state cases at 1440/390/360 CSS pixels and
  350 at actual 200% browser zoom. Keyboard-only registration/key/Registry handoff,
  forward/reverse modal focus, copy feedback, role restrictions and unknown-outcome
  recovery passed. Fixed modal Tab wrapping, narrow classifier fields and the
  modern HTML input pattern; desktop/narrow/native-zoom screenshots reviewed.
  Zero fixture nonlocal requests or browser errors; 10 loopback asset/method
  confinement checks passed. Synthetic fixtures do not verify production APIs,
  real clipboard permission, authentication or provider behavior.
- [x] **M2.5** Bind each proposed feature change to a concrete acceptance scenario
  and preserve existing identity, confirmation, receipt and recovery contracts.
  Verified 2026-09-19: docs/ux/acceptance-scenarios.md maps UX-01 through UX-33
  to M3/M4 changes and the installer handoff, with Given/When/Then outcomes and
  source/test grounding. Independent review corrected Registry readback,
  confirmation cancellation and activity/action wording; role, receipt-race,
  shared-impact and historical-result boundaries agree with the current contracts.
- [x] **M2.6** Synchronize all project documents, directives, continuation state,
  memory and applicable configuration contracts; pass a fresh consistency review.
  Verified 2026-09-19: all 26 authored Markdown documents reviewed; 285 local links
  and 3 heading anchors resolve. Source-grounded API checks pass for 425 OpenAPI
  references, 48 unique operations/route-security mappings and 16 request-property
  sets. Bootstrap schema/example, JSON/XML, version and Bicep parameter checks pass.
  Direct-browser permission, design/production boundaries, directives, state and
  memory agree. Parent/supporting scoped diff reviews and whole-tree whitespace
  checks pass, including the new UX assets/harness. Retained application and
  configuration contracts are unchanged; task-owned browser artifacts and server
  were cleaned up. At M2 closure, M3-M6 remained unchecked.

## M3 — Core onboarding and everyday management

- [x] **M3.1** Implement clear getting-started navigation and copy; browser-verify
  the route from a new installation to first registration.
  Verified 2026-09-20: production-component tests and the actual-component Chrome
  host exercise the empty installed-state route from Getting started/Overview to
  registration, role-correct actions and explicit prerequisite failures.
  Prerendered controls wait for interactivity; navigation and keyboard focus work
  at desktop/narrow widths. The installation state and identity are local fixtures.
- [x] **M3.2** Complete registration with both new and reused blueprints; test
  validation, double submission, defaults and an interrupted response.
  Verified 2026-09-20: reviewed new/reused-blueprint flows pass component and Chrome
  checks for validation, catalog failures, repeated submission and explicit
  defaults without silent downgrade. Creation waits for browser acknowledgment
  of the non-secret recovery ID; no POST is sent before positive acknowledgment
  or after retention failure/disconnection. Interrupted results use exact-ID
  readback, never another blind create.
- [x] **M3.3** Implement a consistent endpoint/ID/key handoff and non-secret sample
  command; test one-time display, copy feedback, navigation and lost-key recovery.
  Verified 2026-09-20: shared registration/replacement handoff passes one-time
  disclosure, issuance binding/expiry, saved-key acknowledgment, copy success/
  denial and lost-key replacement cases. Real Chrome navigation confirms the
  unsaved-key warning; global interactive routing prevents enhanced-navigation
  bypass. Commands contain no key and require the sample's HTTPS endpoint contract.
- [x] **M3.4** Improve provisioning progress and administrator handoff; test manual
  and permitted automatic completion, consent challenges, refresh and reopen.
  Verified 2026-09-20: component/Chrome cases cover manual completion, circuit-only
  operation/agent-bound automatic handoff, consent/claims recovery, refresh/reopen
  and unknown-result readback. Canceled/stale confirmation and superseded-route
  callbacks cannot dispatch. Controlled-clock tests verify the exact five-minute
  polling bound; no real Microsoft sign-in or Registry mutation was performed.
- [x] **M3.5** Verify the full sample gate through evaluation, model callback and
  ingestion; prove denied/stale/expired proof never starts or repeats generation.
  Verified 2026-09-20: actual sample callback/clock/transport tests cover denial,
  malformed/mismatched/expired proof and expiry after activity ingestion; valid
  proof permits one model call and one original-receipt submission. SQL receipt/
  configuration races reject stale submissions without regeneration. HTTP 202
  receipt shape, identity and processing status are validated, without claiming
  delivery. As UX-11 specifies, the client cannot atomically observe every remote
  policy change before an external callback. No live model/provider was called.
- [x] **M3.6** Correct agent cursor round-tripping, name/external-ID search,
  pagination and fleet totals; test more than 100 records and stable filtered pages.
  Verified 2026-09-20: unit, owned LocalDB and Chrome checks traverse 237 records
  as 100/100/37 and 137 filtered matches as 100/37, including tied SQL GUID ordering
  and exactly full final pages. Opaque cursors, literal name/external-ID search,
  filter persistence and late-response suppression pass. Overview uses complete
  filtered totals; missing/failed counts stay unavailable. Readiness accepts Ready
  separately from liveness Healthy.
- [x] **M3.7** Verify credential replacement/revocation, enable/disable, audit and
  operation navigation, and truthful Gateway-only deletion wording.
  Verified 2026-09-20: production-component and Chrome cases pass replacement
  handoff, acknowledged revocation, last-key protection, enable/disable and
  unknown-result metadata readback. Late selections cannot expose another
  agent's credential. Role-specific history links and forbidden routes are
  checked; deletion clearly leaves Microsoft identities, shared policy and
  external hosting intact. Authentication/API data are synthetic browser fixtures.
- [x] **M3.8** Pass focused regression tests, Chrome journey/accessibility checks
  and independent review for the complete core experience.
  Verified 2026-09-20: final clean authored-source Release build with SDK 10.0.401
  passed with zero warnings/errors. Source 27, Unit 282, provider/worker 60, UI 110,
  Setup 314, tooling 65 and real SQL 69 total 927 .NET tests, zero failed/skipped.
  Pester 25, packaging, abort 106 and policy-metadata 30 checks passed; final
  source/hash guard and owned-workspace cleanup passed. Browser-host isolation
  checks passed 119 fixture plus 63 HTTP/rendering/asset checks. Installed Chrome
  passed 180 checks at 1440/390/360 widths and actual 200% zoom, including keyboard,
  modal focus and recovery retention; zero nonlocal requests or browser errors.
  Six final screenshots reviewed. Independent review confirms all five findings
  addressed with no new significant issue. Local fixtures do not close M5/M6.
- [x] **M3.9** Synchronize all project documents, directives, continuation state,
  memory and applicable configuration contracts; pass a fresh consistency review.
  Verified 2026-09-20: all 26 authored Markdown documents, directives, UX design,
  continuation and memory reviewed/synchronized; 297 local links and 3 heading
  anchors resolve. API/configuration review verifies 426 OpenAPI references,
  48 route/security mappings and 16 request-property sets. Guides agree on
  retained-ID acknowledgment, confirmation binding, HTTPS sample compatibility,
  readiness, listing and sample-result limits. Scoped independent consistency
  review, final diff, tracked/untracked whitespace and JavaScript syntax checks
  pass. Task-owned browser server, profiles, screenshots and build/test workspaces
  cleaned up; prior authored work preserved. No Azure deployment or live-provider
  acceptance claimed. M3 is closed; M4-M6 remain unchecked.

## M4 — Protection configuration and runtime verification

- [ ] **M4.1** Organize existing protection functions into focused optional tasks;
  verify a core-only registration has no misleading incomplete/error state.
  Verified 2026-09-20: focused overview/connection/policy/runtime/collection/defaults
  routes render the actual components. Role fixtures and Chrome at 1440/390/360
  pixels and 200% zoom keep all-Off registrations neutral and hide unrelated
  editors. Fixed nested denied-page headings and overlapping runtime actions.
  Reopened 2026-09-24 for the novice setup feedback: distinguish an ordered,
  optional Purview setup journey from unrelated administration tools. Show the
  current step, prerequisites and exact next action; allow explained revisits
  without implying that tab navigation changes policy or completes a step.
- [x] **M4.2** Unify registration/protection summaries across overview, list,
  details and Settings; distinguish requested configuration from effective behavior.
  Verified 2026-09-20: shared projection is wired to all four views. Tests verify
  unknown versus Off, four modes, inactive registration and expiry equality;
  backend metadata bounds readiness by connection/inventory/behavior expiry.
  Chrome verifies actual parent-page bindings, simulation, Off and expired states.
  Current protection is not inferred from a configuration operation or receipt.
- [ ] **M4.3** Improve the Windows companion connection and inventory handoff
  through an explained outcome and the next permitted task; test cancellation,
  wrong tenant/account, stale inventory and reopening the task.
  Verified 2026-09-20: component/backend and Chrome cases verify exact tenant,
  actor, operation, generation and launch expiry; cancelled/late review dispatch
  is rejected. Same-actor GET restores the accepted launch without renewal.
  Wrong/stale evidence cannot confirm connection; inventory refresh preserves
  the prior choice visibly without reselection. Actual Windows/Microsoft sign-in
  remains M6; the local fixture never authenticated or ran a provider.
  Review correction verified: prior invalid/404 operation errors are cleared on
  clean-task navigation. Both component cases and real Chrome transitions pass;
  retained known-operation links still preserve recovery context.
  Follow-up 2026-09-22: a live expired companion launch exposed a disabled-refresh
  dead end. The UI now permits a fresh reviewed authorization for a known expired
  waiting connection, preserving the old operation and rejecting its old command.
  Exact actor/tenant/target/expiry/launch bindings, row versions, pending/unknown
  work and operator visibility remain guarded. All 229 UI cases and 106 isolated
  actual-component Chrome checks pass; hosted promotion is tracked under M6.5.
  Reopened 2026-09-23: the production completion API returns the original
  connection operation, not its separate approval ID. The UI and browser fixture
  incorrectly treated those IDs as interchangeable. Distinct-ID completion,
  lost-response/legacy-link recovery, explicit UTC wording and truthful provider
  failure reporting require fresh verification before restoring this check.
  Verified 2026-09-23: corrected distinct-ID completion and guarded original-ID
  GET recovery; pending/unknown work suppresses stale helper controls. All 251 UI
  cases and a fresh actual-component Chrome run (115 M4, 180 M3) pass, including
  retained browser IDs, legacy approval links, lost responses, disposal races
  and `VerificationFailed` resources after expiry. Failed/handoff screenshots
  were inspected. This restores the local handoff item, not provider access,
  DLP enforcement, hosted promotion or M6 acceptance.
  Separate hosted follow-up 2026-09-23: canonical UI-only promotion finished
  Verified at 04:28 UTC (ACR de7, digest `65d5d4e5...`, revision 0000002);
  predecessor/bootstrap bytes and API/worker/queue/identity boundaries remain
  unchanged. Chrome reopened and refreshed the original failed operation;
  ten read-only checks and visual inspection verify the retained ID, truthful
  failure, UTC/reference guidance and available reviewed refresh. No new live
  completion was attempted. Separately, the user registered the exact missing
  provider reference at 06:09 UTC on 2026-09-23 without role/policy writes.
  A distinct app-identity read at 06:26 UTC verified 354 definitions and remote
  exit zero. These are prerequisites, not fresh Gateway completion or DLP
  acceptance; this does not close M4.7/M4.8 or M6.
  Reopened for first-time UX feedback 2026-09-23: download trust was not explained
  at the action point, and console output unnecessarily required saving/uploading
  a file. Explicit per-file trust guidance and a bounded primary paste flow with
  optional upload require new component, large-result, actual Chrome and
  source-bound hosted verification. The user's separate connection completed
  at 06:50 UTC with 354 definitions; do not restart or resubmit it.
  First-run correction verified 2026-09-23: six ordered Windows steps put the
  permitted per-file trust command before execution; direct paste is primary,
  with optional upload and identical strict evidence/review checks. All 278
  clean-source UI tests pass without skips; the owned fixture passed 139
  self-tests and 63 HTTP/isolation checks. Actual-component Chrome passed 129
  M4 and 180 M3 checks, including a 103,433-byte, 354-definition result through
  the same finite transport as production, edit/replacement invalidation,
  original-ID recovery, keyboard use and 200% zoom. Screenshots were inspected;
  the separate synthetic prototype passed 1,514 checks.
  Canonical UI-only promotion finished Verified at 08:23 UTC: ACR de8, digest
  `4a723969...`, revision 0000003. Exact readback completed verification after
  failed checks without a second build/deployment or receipt relabeling. Authenticated
  Chrome passed 13 read-only checks at 08:25 UTC, including correct identity,
  unchanged served companion bytes and Refresh required after readiness expiry;
  no stale handoff was exposed, and no console errors occurred. The existing
  connection was not restarted or resubmitted. New live paste submission,
  DLP enforcement and the broader M4.7/M4.8 and M6 acceptance remain unverified.
  UX/API/test guides, README, directives/memory and continuation/deployment state
  are synchronized; structural links/contracts and final diff checks pass.
  Reopened for completed-operation feedback 2026-09-23: a technical Completed
  timeline is not an understandable outcome or onward journey. Explain what
  connection verification accomplished, why it was needed, what it did not
  enable/test, and the next permitted action. Verify automatic read-only progress
  and current-state refresh, safe reopening/expiry, and no repeated completed
  mutation. The earlier paste/trust proof remains valid within its own scope.
  Implementation and focused verification 2026-09-23: explained outcomes,
  purpose-specific skipped steps and exact onward actions replace the dead end.
  Bounded GET-only observation refreshes the required current state without
  replay; cross-task errors no longer trap recovery, and replacement runtime
  readiness reschedules parent expiry without rebinding samples. Fresh source
  passes 314 UI cases and 140 M4/180 M3 actual-component Chrome checks, including
  the full clicked connection/policy/test/agent path, keyboard and 200% zoom.
  Bounded independent follow-up confirms both review findings resolved with no
  new significant issue. Restored after canonical de9 promotion finished Verified
  at 16:37 UTC, digest `5319998f...`, revision 0000004. Authenticated Chrome passed
  25 read-only checks at 16:42-16:45 UTC: explained expired/current context,
  historical 10:26 UTC success, usable reviewed refresh, clipped announcement,
  unchanged helper bytes and clicked policy/runtime prerequisite navigation.
  The live screenshot was inspected; no connection, policy or sample was replayed.
  Prior bootstrap/receipt bytes and API/worker/queue/identity boundaries remain
  unchanged. This restores the UI handoff item, not M6 provider enforcement.
  Reopened 2026-09-23 after the 18:08 UTC live completion failure: the API accepted
  the companion-result reviews, but no subsequent confirmation/completion was
  observed. Current-source Chrome reproduced the exact generic error after the
  new Go to companion result link, with zero follow-up confirmations/mutations.
  The original operation is preserved; it later expired while still awaiting
  completion. Root-cause correction and fresh end-to-end verification are required.
  Recovery correction verified 2026-09-23: the browser preserves the shortcut's
  scroll fragment while enforcing origin/path/query and exact recovery-ID binding.
  Expected pre-dispatch retention failures explain that no confirmation or
  protection change was sent. The uninterrupted shortcut/paste/review/submit
  journey now completes exactly once under the original connection ID. All 320
  fresh-source UI cases and 142 M4/180 M3 Chrome checks pass; the initial
  evidence-edit test timing failure and successful reruns are disclosed on M4.7.
  Canonical UI-only ACR `dea` finished Verified at 19:39:39 UTC, digest
  `8a31d8fa...`, revision 0000005. Authenticated Chrome passed 28 bounded hosted
  checks at 19:43-19:45 UTC: tested recovery/unchanged companion bytes, the
  repaired fragment guard and its rejection boundaries, original expired
  operation, disabled paste, usable reviewed refresh and a real GET-only refresh.
  Its outcome screenshot was inspected; no console errors/warnings occurred.
  No live review, confirmation, completion, policy or sample was invoked. The
  previous launch remains expired; a fresh timed handoff waits for the
  administrator. This restores the UI handoff item, not M6 provider acceptance.
  Reopened 2026-09-24: the connection page must summarize the actual returned
  classifier count and freshness, not ask for an unused SIT selection. Select
  policy classifiers once in the policy step. Active observation needs visible,
  accessible activity feedback; paused, stale and failed reads must not look
  like ongoing provider progress. Preserve the separate collection selector.
- [ ] **M4.4** Verify shared blueprint policy scope, multiple classifiers,
  thresholds, reviewed impact, concurrent edits and deferred new-blueprint binding.
  Expanded acceptance 2026-09-24: investigate the actual shared-policy dead end
  without replaying accepted work. Provide explained, validated starting
  thresholds for newly selected classifiers while preserving existing explicit
  thresholds and unknown legacy evidence. Make prerequisite/expiry recovery
  actionable and preserve the user's draft where recovery can safely do so;
  refreshed context always invalidates old review/confirmation authority.
  Local recovery correction verified 2026-09-24: 24 real owned-SQL administration
  cases, zero skipped, cover reviewed acceptance-only inventory rebinding for
  the same saved policy, all four modes, identity/settings/agent-choice
  preservation, runtime-proof invalidation, one-outbox replay and rejection/
  rollback for renamed/missing types, unknown thresholds, row-version drift,
  generation changes and expiry equality. Source-bound provider regressions
  passed 33 cases, zero skipped, including incomplete reconciliation readback
  causing zero creates/updates. This is local evidence only; complete UI/browser
  acceptance and canonical backend/executor delivery are still required.
  Verified 2026-09-20: policy UI tests cover 1-100 distinct classifiers, duplicate
  catalogs, explicit ordered thresholds, shared acknowledgment and changed drafts.
  Real owned SQL tests verify exact two-SIT round trips, stale row-version
  rejection/rollback, one-outbox replay, and deferred identity/name/actor binding,
  existing-profile conflict and expired inventory. Chrome exercises actual
  shared-scope confirmation, conflict and same-operation unknown-result recovery.
- [x] **M4.5** Verify all supported policy modes and independent Prompt Shields
  choices; preserve receipt invalidation when effective protection changes.
  Verified 2026-09-20: all four modes round-trip through UI/API/real SQL without
  collapsing simulation variants or rewriting sibling Prompt Shields choices.
  Actual policy mutation clears prior behavioral certification; existing SQL
  receipt/configuration-race tests pass. Unknown legacy modes require review
  rather than becoming simulation. No provider policy-tip behavior is claimed.
- [x] **M4.6** Verify approved runtime sample review/execution/status, positive and
  negative behavior, expiry and unknown outcomes; preserve ephemeral sample handling.
  Verified 2026-09-20: actual backend runner/validation/evidence tests exercise
  negative-first probes, expected/incorrect verdicts, missing roles, scope-only
  blocks, context/expiry/Off rejection, byte bounds and ephemeral disposal.
  Reproduced and fixed the timer to stop at 60 seconds with the injected clock,
  even for a noncooperating dependency. Actual private JavaScript checks exercise
  commitments, batching, retention, single POST and disposal. Chrome runs the real
  HTTPS portal/antiforgery path with a finite synthetic executor, including
  approval, erasure, lost-response GET recovery and historical report reopening.
  Contradictory reports cannot claim verification. These are local boundaries,
  not live Purview behavior or deployed capture-setting acceptance.
  Review correction verified: serialized browser initialization checks its
  captured context after each await and erases/disposes stale returned sessions.
  Close/disposal race regressions and a real Chrome delayed-module close/reopen
  journey pass; no late session can become the active sample flow.
- [ ] **M4.7** Pass focused tests, Chrome workflow/accessibility checks, API schema
  conformance and independent review of the protection experience.
  Expanded acceptance 2026-09-23: a novice must be able to continue from tenant
  connection through inventory, reviewed shared-policy configuration, approved
  runtime verification and the resulting protection summary without external
  instructions or a dead-end operation log. Each task/state must answer what
  happened, why it matters, what remains unverified, and what the user can do
  next. Validate Completed, pending, failed, unknown, skipped and expired states;
  unavailable prerequisites and roles must explain their limits rather than
  expose unusable actions. State changes must update reactively, preserve context
  across navigation/reopen, and never auto-create, auto-confirm or replay work.
  Exercise the actual action links/buttons through the journey in Chrome,
  including keyboard-only use, narrow layouts and 200% zoom. Optional protections
  Off remain a valid completed choice. UI/provider proof remains distinct.
  Verified 2026-09-20: final clean-source Release build passed with zero warnings/
  errors. Source 27, Unit 313, provider/worker 60, UI 216, Setup 314, tooling 65
  and real SQL 81 total 1,076 .NET cases, zero failed/skipped; Pester 25, packaging,
  abort 106 and policy metadata 30 passed. Source/hash guards and cleanup passed.
  Actual private JavaScript protocol checks passed 18 cases. Chrome passed 103
  M4 and 180 M3 regression checks at desktop/narrow sizes and actual 200% zoom,
  with zero nonlocal requests or unexpected script/console errors; one deliberate
  runtime-response HTTP 502 diagnostic was explicitly matched. Current screenshots
  were visually reviewed. Independent review's two lifecycle findings were
  reproduced, fixed and verified; bounded follow-up found no new significant issue.
  Reopened 2026-09-23 for the corrected real completion response contract and its
  actual-component recovery/failure scenarios; older browser counts do not prove
  the correction.
  Historical de9 proof 2026-09-23: 314 fresh-source UI cases with no failures or
  skips; 144 worker-faithful fixture and 63 HTTP/isolation checks; 140 M4 and 180
  M3 Chrome checks plus 18 private-module checks. Source-traced review findings
  in cross-task recovery and effective parent expiry were first reproduced in
  three failing actual-Settings cases, then corrected and exercised in Chrome.
  These synthetic checks do not establish Microsoft-provider behavior. Bounded
  reviewer follow-up confirms both fixes and unchanged substantive assertions,
  with no new significant issue; it inspected source/TRX rather than rerunning
  tests. Fresh structural checks pass 427 OpenAPI references and 48 route/security
  mappings. The final synthetic design run passes 1,649 checks, including actual
  Stop/Resume, terminal current-context readback and matching current-verification
  wording; the earlier 1,647-check run did not cover the later edits and was not
  reused. Those desktop/narrow/200% screenshots were inspected. The de9 hosted
  readback passed 25 checks on the real administrator session, including actual
  prerequisite-link navigation; zero console errors/warnings. No live policy or
  runtime sample was submitted. The complete positive journey remains explicitly
  local synthetic proof; live-provider acceptance is not inferred.
  Reopened 2026-09-24 for holistic novice-flow acceptance: verify one uninterrupted
  connection/inventory summary -> shared blueprint/SIT/threshold review -> policy
  observation -> mode-appropriate next step. Include a catalog expiring during
  editing, saved versus draft values, actionable blockers, pending/paused/failed
  observation, reduced motion, keyboard, narrow layouts and actual 200% zoom.
  Animations communicate monitored activity, never fabricated completion or
  proof that Microsoft is making progress. Historical test totals do not close
  this expanded acceptance.
  Current partial verification 2026-09-24: fresh actual-component build passed
  144 fixture and 63 HTTP/isolation checks; installed Chrome passed 146 M4 and
  180 M3 checks, including the final collapsed earlier-task history, exact new
  defaults, edited reselection, single blueprint selector, mobile layout and
  reduced-motion activity. No nonlocal requests or unexpected browser errors.
  A fresh 173-case parent/activity run passes after correcting three strict
  fixture expectations. The scoped disposal test now disposes the actual
  component tree and verifies cancellation before releasing a late response.
  Two further host-integration cases reproduced missing parent gating during
  prerequisite reads; Refresh, blueprint changes and Cancel edit are now gated
  without resetting the draft or feeding the child's busy state back to itself.
  Final application verification 2026-09-24: the complete clean authored-source
  baseline including maintenance fixes copies 960 inputs, parses 73 PowerShell
  sources, and passes 1,454 .NET tests (398 UI and 138 owned SQL), 435 StrictMode
  Pester tests across 13 files and all three portable gates, with zero skipped
  or unrun cases and an unchanged-source guard. Structural documentation/config
  validation passes 329 local links and 48 OpenAPI operations with declared
  runtime/provider exclusions. The final owned HTTPS/actual-component Chrome rerun
  passes 146 M4 and 180 M3 checks with no nonlocal requests or unexpected browser
  errors. The fixture was gracefully stopped and its temporary certificate file
  removed. These are local results, not live Microsoft authorization.
  Bounded canonical v2 maintenance compatibility now passes actual local
  admission for the exact originally accepted custom resource group. Original
  bootstrap evidence and separately verified UI predecessor receipts remain
  intact. The maintenance fixtures cover original
  versus promoted-image proof, before/after predecessor drift rejection and
  healthy maximum-scale revisions without relaxing replica readiness.
  Live predecessor readback passed; complete Full verification correctly stopped
  on an observed B1 plan where original evidence requires B2. One scoped update
  restored B2/one worker and passed the original executor host checks at 07:23
  UTC, without changing original input bytes or deploying application code.
  A later final-image mismatch was reproduced and fixed by carrying the verified
  UI predecessor through all current-image checks, while keeping original image
  reports unchanged (51 image/admission cases pass). Actual joint-gate tests
  also reproduced and fixed a skipped worker-preservation branch; joint/revision
  fixtures pass 47 cases. Complete live canonical Full baseline verification
  passed at 08:07 UTC with original state/configuration unchanged. This establishes
  baseline eligibility only. Canonical local Package/Prepare also passed: 723
  packaged inputs match the fresh tested snapshot, the upload allowlist and
  98-file compiled migrator bundle are pinned, and the compiled EF model is
  unchanged. No source approval, remote artifact build or deployment is implied.
  The bounded independent integration review completed with no significant
  issues after source/diff/test/contract inspection and PowerShell parsing;
  it did not approve maintenance or deployment. Exact-candidate
  release qualification, final closure synchronization and canonical hosted
  delivery remain open; no current-source deployment or live policy success is
  claimed.
  Reopened with M4.3: prior checks did not exercise the companion shortcut and
  subsequent confirmation as one uninterrupted journey. The new red Chrome
  reproduction must pass after correction, alongside recovery/privacy boundaries.
  Current correction verified 2026-09-23: 146 focused cases and the final full
  320-case UI run pass with zero skips. The first full run failed one existing
  evidence-edit timing assertion; its three isolated cases and the full rerun
  passed unchanged. Its scheduling cause is not established, and no input-handling
  fix is claimed. The new owned source build has zero warnings/errors; 144 fixture
  self-tests, 63 HTTP/isolation checks, 142 M4 and 180 M3 Chrome checks and 18
  private-runtime protocol checks pass. False acknowledgment, JavaScript failure,
  disconnection and timeout cannot send confirmation or mutation. Chrome covers
  the uninterrupted shortcut-to-completion regression, registration compatibility,
  URL context rejection and recovery/privacy invariants. Two current handoff/
  recovery screenshots were inspected; no nonlocal fixture requests or unexpected
  script/console errors occurred, with one expected synthetic HTTP 502 diagnostic.
  The small correction received direct source/call-site review, not a new
  independent review; the earlier protection-experience review remains historical.
  Canonical `dea` delivery and the 28 bounded hosted checks recorded on M4.3 pass.
  Fresh structural API/role/configuration verification is recorded on M4.8.
  The positive completion journey remains synthetic, not a fresh live companion
  completion or provider-enforcement claim.
- [ ] **M4.8** Synchronize all project documents, directives, continuation state,
  memory and applicable configuration contracts; pass a fresh consistency review.
  Verified 2026-09-20: all 27 authored Markdown documents and relevant contracts
  reconciled; local links/anchors, complete tracked/untracked diff and syntax
  checks pass. Independent supporting review verified 427 OpenAPI references,
  48 route/role/security mappings and 19 property sets, plus bootstrap schema/
  example, JSON/XML/build inputs, version and Bicep bindings. UX copy/prototype
  updates passed 1,504 separate synthetic design checks; they do not replace
  production or provider acceptance. Directives/memory retain deadline, recovery,
  TLS-fixture and late-session ownership learnings. Task-owned hosts, certificates,
  profiles, screenshots and source workspaces were cleaned. That review closed M4
  at the time; the 2026-09-23 completion-ID correction reopens synchronization.
  M5's later qualified release and fresh M6 acceptance retain their own entries.
  Historical de9 synchronization 2026-09-23: non-UX guides, directives, memory and
  continuation state describe the guided outcomes, task-scoped recovery and
  effective runtime-readback expiry. Fresh structural checks passed on 943 stable
  authored inputs, 27 Markdown documents, 321 local links, 427 OpenAPI references
  and 48 route/security mappings, plus current schema/configuration/build
  contracts. Tracked whitespace and the retained task-start diff checks pass.
  The UX package, UX-34, prototype and driver are synchronized; the final design
  run passes 1,649 checks with zero nonlocal requests/browser errors. A keyboard
  test now actually enters keyboard modality before checking focus visibility.
  Hosted de9 results, exact receipt/image/revision, preserved boundaries and
  read-only browser limits are synchronized with continuation/deployment state.
  Local synthetic proof remains distinct from live-provider acceptance. Owned
  fixture hosts/profiles are closed; superseded copies/captures were removed by
  exact inspected paths, retaining accepted proof. This restores M4 closure
  without relabeling M5's historical release or closing any fresh M6 item.
  Reopened for the new companion-shortcut failure and its corrected verification,
  hosted delivery and documentation synchronization.
  Recovery synchronization verified 2026-09-23: all 27 authored Markdown
  documents and relevant contracts were reviewed. UX/API/architecture/test
  guidance, READMEs, directives/memory and continuation/deployment state now
  distinguish the corrected browser guard, current `dea` delivery, historical
  de9 proof and unrun live-provider acceptance. The prototype's separate hash
  routing is explicitly not recovery-protocol evidence. Fresh structural checks
  pass on 944 stable authored inputs, 323 local links, 427 OpenAPI references
  and 48 route/security mappings, plus schema/configuration/build contracts.
  The precise production delta from the red reproduction and the new untracked
  helper were inspected; whitespace checks pass. All 746 deployed inputs still
  match the tested copy, and the original bootstrap/four predecessor receipts
  remain byte-identical. The failed initial post-check and its successful
  same-intent readback are preserved without a second build/deployment.
  Owned hosts/profiles/certificates are closed; only six inspected temporary
  source/publish/preparation paths were removed, retaining manifests, red/green
  reports, browser proof, accepted snapshots and operational receipts.
  This restores M4 synchronization, not M6 provider or fresh-environment acceptance.
  Reopened 2026-09-24 with the novice-flow corrections. Synchronize the selected
  framework approach, ordered setup versus optional tools, inventory summary,
  threshold-starting-value rules, activity semantics, recovery behavior and
  actual verification in all affected guides, prototype, directives and contracts
  before restoring closure. M5's historical qualification and M6's unrun
  fresh-environment/provider acceptance remain distinct.
  Fresh design-fixture verification 2026-09-24: the synchronized current
  prototype/driver pass JavaScript syntax and 1,649 isolated installed-Chrome
  checks (including keyboard, narrow layouts and actual 200% zoom), with zero
  nonlocal requests/browser errors. Current outcome, shared-policy review and
  keyboard/zoom screenshots were visually inspected. This verifies synthetic
  design continuity only, not hosted authorization or provider behavior;
  final whole-project/current-release synchronization is still pending.

## M5 — Release packaging and deployment readiness

The 2026-09-22 qualification below belongs to its exact original release.
The 2026-09-24 full-stack novice-flow follow-up is a different candidate.
Its source tests have passed, but artifact, private maintenance, hosted
authorization/redaction, new-source planning and final review/synchronization
gates are reopened. Historical passing evidence remains historical, not approval
of the new candidate. M6 remains blocked until current M4/M5 closure.

- [x] **M5.1** Build and test the exact candidate from a clean source copy; prove
  no dependency on old local checkpoints, binaries or unpublished working files.
  Reverified 2026-09-25 KST for the user's explicit B1 selection. The replacement
  contract acknowledges only an already-allocated, exact B1/B2 change and carries
  that selection through actual read-only host verification, preserving the same
  one-worker Windows/private identity boundary and original B2 receipts. Fresh
  installation now selects B1. The fresh 963-input clean copy/75 PowerShell parses
  passes a zero-warning/error Release build, all 1,478 .NET cases (including
  138 owned-SQL cases), 538 StrictMode Pester cases across 15 files, all three
  portable gates and the unchanged-source guard; none skipped or unrun. All
  723 inputs in new candidate `7e18c7d4...` match the passing copy. Canonical
  Prepare pins the compiled toolchain and verifies the unchanged model/zero-DDL
  intent. Local admission passes without changing original state/configuration.
  The actual isolated canonical baseline passed at 2026-09-24 17:49:30 UTC,
  returning the explicit B1 echo and result `f30495f3...`. Genuine GPT-6 Astra
  follow-up independently verified the exact bindings, six-file delta and actual
  read-only consumers and passed all 65 focused StrictMode cases; it approves
  exact `7e18c7d4...` source with no significant findings. New Plan admission,
  artifact qualification and hosted delivery remain separate, unfinished gates.
  Historical d9 approval was not relabeled for these replacement bytes.
  Reopened after artifact-bound preflight on 2026-09-24: Azure returned
  `containerapps` in the existing API/worker ARM IDs while the maintenance
  snapshot compared `containerApps` case-sensitively. All other independently
  checked ownership/source/environment/image/revision-mode fields matched.
  No application mutation was attempted. The correction covers workload,
  revision, replica, queue and scoped role/resource readback, including the
  private observer; duplicate casing aliases remain rejected and signed
  fingerprints/identity bindings are not normalized. Targeted verification:
  92 actual-consumer Pester cases and all 89 directly affected .NET tooling tests
  pass, including 24 finite private-transport cases. Actual corrected read-only
  snapshot/revision calls pass for the three owned live apps at 15:29 UTC:
  complete inventories of 2/14/6 revisions, one active each, with unchanged
  original inputs and no mutations. Reverified 2026-09-24: the replacement
  963-input clean copy/75 PowerShell parses passes a zero-warning/error Release
  build, all 1,478 .NET cases (including 138 owned-SQL cases), 510 StrictMode
  Pester cases in 15 files, all three portable gates and the unchanged-source
  guard. No cases were skipped or unrun. A first attempt correctly failed a new
  mock's omitted switch under StrictMode; explicit switch binding fixes the
  fixture without changing production or weakening assertions. All 723 frozen
  inputs in new candidate `d9c98751...` match the passing copy. Canonical Prepare
  pins its compiled migrator bundle and confirms the unchanged model. Fresh
  source scanning again reports nine individually inspected non-secret public
  identifiers/object names/source hashes, not zero findings. Source review,
  artifact qualification and deployment remain separate gates. The `c9fec9e2...`
  source and artifact results below cannot approve these replacement bytes.
  Reopened again 2026-09-24: actual Build exposed unpinned ARM metadata reads.
  The exact Storage read reproducibly rejects automatically selected API
  `2026-09-01` with `NoRegisteredProviderFound`, despite an already Registered
  provider. Ten controls across the same five resources pass with explicit
  reviewed versions. The two remaining generic metadata loops now pin all eight
  reads; real-loop regressions reproduced the defect and 55 metadata/baseline
  cases pass, preserving mismatch rejection and no retry/default behavior.
  Reverified 2026-09-24: a new 961-input clean source copy/74 PowerShell parses
  passed a zero-warning/error Release build, all 1,454 .NET tests (including
  owned SQL), all 465 StrictMode Pester cases in 14 files, the three portable
  gates and unchanged-source guard. None were skipped/unrun. Every one of the
  723 inputs in new immutable candidate `c9fec9e2...` matches that tested copy;
  only the two metadata modules differ from `d7613ff7...`. Absolute-bound Prepare
  pins a fresh 98-file bundle with unchanged compiled model. The actual redirected
  canonical Full verifier also passed at 12:47 UTC without changing original
  state/configuration. New exact-source review, Plan and delivery remain separate.
  Earlier `d7613ff7...` source approval and scans are not relabeled for this fix.
  Earlier same-day reopen: an isolated-verifier diagnostic correction
  preserves bounded relative source locations across English/Korean stacks while
  suppressing provider bodies and rejecting nonzero exits. Actual child-process
  regressions reproduced the missing context; all 44 baseline/provider diagnostic
  cases pass. Reverified 2026-09-24 after that correction: a new 960-input clean
  Release build passed with zero warnings/errors, 1,454 .NET tests, 447 StrictMode
  Pester cases across 13 files, all three portable gates and the unchanged-source
  guard. No cases were skipped/unrun. All 723 packaged inputs in new immutable
  candidate `d7613ff7...` match those tested bytes. Canonical absolute-bound Prepare
  pins a new 98-file migrator bundle with the unchanged compiled model. The
  exact-source review and downstream delivery gates remain separate; no earlier
  frozen bytes or approval were relabeled.
  Earlier source verification 2026-09-24: the fresh 960-input clean baseline
  passed 1,454 .NET tests, 435 StrictMode Pester cases across 13 files, all three
  portable gates and the unchanged-source guard, with zero skipped/unrun cases.
  All 723 inputs in immutable maintenance candidate `f481e7f7...` independently
  match those tested bytes. Canonical Package/Prepare checked the generated
  upload allowlist and pinned the 98-file compiled migrator closure; the model
  is unchanged. This source proof does not close the artifact/hosted gates below.
  Historical qualification 2026-09-22: froze all 928 authored inputs before build; corrected source
  `sha256:e03180c2b9e7b2fe57b5cc05c59f96730acd6a5a0049a96fa30a36110879bc0d`,
  ZIP `b8eac2d12b13d630b39a17efec6b4f18fd935f798bdd6dbd3d27ab123b4ea60b`.
  The full short-path clean Release run used SDK 10.0.401, built with zero
  warnings/errors and passed Source 29, Unit 338, provider/worker 139, UI 216,
  Setup 314, tooling 65 and real SQL 126: **1,227 .NET cases**, zero failed/skipped.
  Pester **146**, portable packaging, abort 106 and policy metadata 30 passed.
  Archive/whole-source hash guards, module-export preservation and owned fixture
  cleanup passed. Independent review recomputed all 734 deployment inputs and
  all 928 unique ZIP entries with no extras.
  Earlier publisher version-metadata, HTTPS-ingress and retry-exhaustion findings
  were corrected and regression-tested before this freeze. The old `2bb36...`
  candidate and its later documentation-only `e1909506...` hash are historical,
  not the current release. A deep-path native SQL failure was rejected and the
  same source tested from a short owned path. The configured feed recovered
  before this clean run; earlier NU1900 warnings were not hidden or accepted.
- [ ] **M5.2** Validate API, Admin UI and worker containers plus the pinned Windows
  executor/package-publisher path from that candidate.
  Reboot checkpoint 2026-09-25 KST: genuine `7e18c7d4...` source review and fresh
  canonical Build Plan `f6a307b9...` pass. The Plan's baseline passed at
  2026-09-24 18:43:09 UTC. The following Build used the required 7.6.5/X64
  launcher, but its own fresh read-only baseline failed at 18:53:47 UTC without
  a bounded provider classification/source frame. Its execution directory is
  empty; the failure precedes cloud lease, image/package actions and deployment.
  Original state/configuration hashes remain unchanged, both commands have
  exited, and the user requested a reboot pause. Diagnose before continuing
  the same exact Plan; no new artifacts or hosted acceptance are claimed.
  Reopened 2026-09-24: the new source-only Full candidate requires fresh exact
  image/Windows-package qualification and deployment.
  Historical `d9c98751...` source review passed, but its fresh Build Plan failed
  before approval/build at the actual retained-SKU check. Correlated readback
  attributes a second B2-to-B1 change to MCAPS governance automation, not this
  source. No replacement images/package or application deployment ran. The user's
  subsequent explicit B1 authorization and the reviewed acknowledgment supersede
  the former B2-exception direction; no governance change is required.
  Actual reviewed Build Plan `8a19f909...` passed for `d7613ff7...`; both Build
  attempts stopped during fresh read-only verification, before any action
  checkpoint or image build. The API-version correction requires new source
  qualification and a replacement Plan, not another use of that old approval.
  Replacement `c9fec9e2...` now has passing exact reviewed Build Plan
  `a3cb5183...`; its saved integrity/source/caller/review/target bindings were
  verified. Its first canonical Build passed baseline verification and produced
  API/worker/Admin UI/migrator runs `deb`-`dee`, then stopped before package
  creation: the default 7.6.6 shell does not meet the pinned 7.6.5/X64 contract.
  The actual unchanged prerequisite check reproduced that failure and passed
  with the already-owned Microsoft-signed 7.6.5/X64 installation and EOM 3.10.1.
  The same approved Build completed with that launcher and existing checkpoints,
  without weakening checks: five runs `deb`-`def`, artifact bundle `6bf1f7fc...`,
  actual Windows ZIP `05f3ade2...`. All five images pass fresh OCI
  digest/platform/non-root and regular layer/config scans with zero findings or
  scanner errors. API/worker contract bytes and all 14 SQL/source files match;
  all 1,367 Windows ZIP files reconcile to the manifest, scan cleanly, match the
  publisher's actual embedded ZIP and pass six native/HTTP checks.
  Separate artifact-bound Plan `9c023bfe...` passed canonical admission with
  execution supported. Its read-only preflight then exposed the ARM ID casing
  defect described on M5.1, before application mutation. Replacement source,
  artifacts, validation and hosted acceptance are required; do not execute or
  relabel this candidate to bypass that failure.
  The existing `dea` UI is still live. Preserve the following original-release
  evidence rather than relabeling it as this candidate's result.
  Historical corrected qualification 2026-09-22: canonical `a365q5b` Apply completed all 19
  stages. ACR runs de1-de5 built the API, worker, Admin UI, migrator and publisher
  from the accepted snapshot; immutable manifest/config/layer hashes were checked.
  Actual assemblies report 0.1.0.0, all 14 shipped SQL scripts match source, and
  API/worker `Gateway.Contracts.dll` bytes match. API/Admin health and all four
  served static-asset hashes match the corrected Admin image.
  The exact 193,809,439-byte hosted Windows ZIP is
  `sha256:65033fcc7c86217f2745e195aeac11d161edb103886d604810651c10dcf8ab08`,
  runtime manifest
  `sha256:70098cddc53adfc0665b8489eecc0bb63657475ed76d72bd2ff0dd6cda66a5fe`.
  Its own six native/HTTP checks passed with Microsoft-signed PowerShell 7.6.5/X64
  and EOM 3.10.1; the immutable publisher embeds those exact ZIP bytes.
  Private `/health/ready` admitted the exact worker application identity and
  returned Ready with that source/package; DNS matched the exact private IP,
  and anonymous/invalid JWT requests were denied. An initial 30-second cold read
  timed out and was rejected; one bounded read-only retry passed without provider
  mutation. Temporary worker scaling was restored to zero with all other
  image/identity/configuration/scale bindings unchanged.
  HTTPS regression coverage first reproduced failure on four authenticated
  runtime surfaces. All 25 actual-API ingress cases and ten canonical proof cases
  then passed. Corrected hosted origin readback remains exact HTTPS despite
  misleading client forwarding headers. No forwarded host/client-IP authority
  was introduced. Separate post-probe canonical Verify passed at 09:03 UTC,
  after scale restoration; current worker readback is Succeeded, minimum zero,
  maximum one, with its latest revision ready.
  Linux builds used owned ACR, not a local WSL bypass or OS change. Private
  executor readiness is not compliance connection, policy or enforcement proof.
- [ ] **M5.3** Validate database initialization and applicable migrations using
  real SQL, including receipt consumption, concurrency, outbox and compatibility.
  Reopened 2026-09-24: all 138 current owned-SQL cases and unchanged compiled
  model checks pass, but the new source-only maintenance transaction, zero-DDL
  preservation receipt and private Azure identity/network readback have not run.
  Do not rerun original database initialization to obtain that evidence.
  Historical corrected qualification 2026-09-22: all 126 owned SQL cases passed, including
  ordered/checksummed additive migrations, legacy data/receipt preservation,
  exact receipt consumption, concurrency, rollback, replay, application locks and
  atomic outbox propagation across superseded retry generations.
  The separate real private SQL job `job-a365q5b-db-init-dev-2oeniha` succeeded
  with current model/catalog, exact runtime principals, source/intent receipt
  and private NIC/DNS bindings. Actual schema fingerprint:
  `sha256:68fb19e6e609aa76ac124fe55efafc23d1339b035397deaa404bb860a1c1aae8`.
  Independent reads confirmed Entra-only, TLS 1.2, public access Disabled, zero
  firewall rules and restoration of the exact original administrator.
  The corrected API returned the bounded v1 Attested contract; canonical Apply
  verification and separate post-probe canonical Verify both passed.
  LocalDB is not used as a substitute for Azure identity, networking or remote
  receipt evidence; old q5 database receipts remain bound to their original source.
- [ ] **M5.4** Verify authorization boundaries, queue redelivery, uncertain provider
  outcomes, telemetry redaction and absence of secrets in release artifacts.
  Current B1 source qualification, 2026-09-25 KST: the new complete clean run
  passes 172 provider/worker, 138 owned-SQL and 538 StrictMode Pester cases.
  The fresh local redacted scan of exact `7e18c7d4...` source has zero scanner
  diagnostics and nine findings. Every rule/location/source-line hash matches
  the previously individually inspected non-secret content; this is not a
  zero-finding scan. New actual artifacts and hosted controls remain unrun.
  Reopened 2026-09-24: current clean source passes 172 provider/worker cases,
  138 owned-SQL cases and 465 Pester cases, but the actual new release artifacts
  and hosted positive/negative authorization/redaction checks remain unverified.
  No replay of the three uncertain policy operations is part of qualification.
  A fresh local redacted scan of exact `c9fec9e2...` source completed with zero
  scanner errors and nine findings. Each current file/rule/source-line hash was
  individually matched to inspected non-secret public IDs, a credential object
  name or a source-file hash. This is not a zero-finding scan; exact built
  artifacts and hosted positive/negative controls remain required.
  All five `c9fec9e2...` images and the exact canonical Windows package now have
  fresh complete byte-reconciled scans with zero findings and zero scanner
  diagnostics. These do not qualify the subsequent ARM casing correction or
  hosted controls; this item remains open.
  Historical verification 2026-09-22 against corrected `e03180...`: 139 provider/worker cases,
  the real-SQL suite and 146 Pester cases passed. Focused follow-up passed 52
  worker and 47 SQL cases for processing versus settlement failure, old-step and
  same-step retry supersession, terminal redelivery, transaction rollback and
  explicit unbound legacy handling. All four protection producers bind durable
  attempt generation. Matching producer/worker releases are required; mixed
  rolling deployment and blind legacy replay are not accepted.
  Gitleaks 8.30.1 ran locally without upload or inherited exception files.
  All five corrected Linux images and the exact hosted Windows ZIP had zero
  findings, zero scanner error diagnostics and no credential-file shapes.
  Byte reconciliation checked 8,598 regular files across 24 unique verified layers,
  with no Windows path collisions. The source scan had ten findings: reviewed
  public identifiers, metadata names and a historical hash, with unchanged
  source lines independently compared. This is not a zero-finding source claim.
  Archive-autodetection attempts with PE/Brotli read errors were rejected;
  explicit extraction and ordinary-file scans supplied acceptance.
  Corrected hosted checks passed all **25** health/static/HTTPS/authorization
  probes. All **20** API positive-control trace IDs appeared in the corrected
  workspace; **183** observed request/dependency/trace/exception/console records
  had zero synthetic credential/body-canary matches. Exact private executor
  positive/negative identity checks also passed. UTC strings and positive controls
  prevent empty or future-window results from masquerading as redaction proof.
  These observations do not establish M6 signed-in journeys or per-event
  downstream Agent 365 delivery.
- [ ] **M5.5** Prepare a concrete fresh deployment plan in the pinned subscription:
  region, resources, identities, cost/quota, permissions, source and rollback bounds.
  Current direction 2026-09-25 KST: the user explicitly approves B1 when quota
  permits. Fresh live readback confirms B1/one worker, Windows, Ready/Succeeded;
  the plan offers B1 at one to three workers. Both quota/provider usage reads
  report a regional limit of 13 and usage of zero; the generic quota response
  marks this entry not applicable, so it is not unlimited-capacity proof. The
  existing allocated worker requires no new App Service capacity for maintenance.
  B1 supports the required private endpoint and VNet integration. Continue the
  explicit source-bound B1 adoption and runtime verification; do not require a B2
  exception or alter governance. New source/artifact/hosted gates remain open.
  Fresh canonical read-only M6 planning passed at 2026-09-24 18:13:54 UTC from
  current source `91784310...`: Plan `d4f79588...`, explicit Windows B1, eight
  foundation Create predictions, no Modify/Delete predictions and no Azure
  creation. `applyReady` describes only planning admission. The M6 state has no
  accepted Plan or started steps; quota, write-time authority and provider
  acceptance retain their explicit separate bounds. Fresh maintenance-scope
  policy reads match all 11 inherited assignments and 332 definition/version
  documents, with no exemptions or scope changes during reads. Three unmatched
  preview selectors remain unresolved, not Disabled; actual new artifact-bound
  validation is still required.
  Current maintenance Build Plan `f6a307b9...` now passes canonical B1 admission;
  it does not authorize Execute. Build's subsequent unclassified fresh-baseline
  failure and the user's reboot pause are recorded on M5.2. M6 remains unstarted.
  Historical blocker 2026-09-24: the accepted Windows executor required B2/one
  worker, but actual readback is B1/one worker. Resource Graph and the exact
  Activity Log correlation `060d4321-4671-4b24-abf0-866753e2bb9c` establish a
  distinct B2-to-B1 change at 15:36:55 UTC, after the original successful
  07:22 restoration. Its application is `MCAPSGovernance-AutomationApp`;
  same-subscription delegated-management metadata identifies the matching
  managing tenant. The site remains private/running and Resource Health is
  Available. Its exact governance rule/approved exception remains unverified.
  The completed local-only follow-up found no server-farm SKU write in 335
  retained definition/version files or 47 resolved mutating rules. Its snapshot
  predates the second change; three preview selectors and the actual governance
  workflow remain unobserved. Assignment authorship matches the attributed app,
  but the nearby Lighthouse audit rule is not a supported exclusion.
  No second restoration, bypass tag, governance change, original-state rewrite
  or application deployment was attempted. The rejected Plan attempt is retained;
  the then-requested governance-owner resolution is superseded by explicit B1
  acceptance, not by rewriting original evidence.
  Evidence: `executor-sku-governance-drift-060d4321.json` in the owned
  `.bootstrap/novice-protection-20260924` directory. M6 remains blocked.
  Reopened 2026-09-24: the earlier M6 Plan remains unaccepted and is bound to the
  original source. Current Package/Prepare and genuine independent source review
  pass. Earlier maintenance Plan attempts failed fresh baseline verification;
  a later instrumented read-only Full diagnostic passed without a source change
  or established root cause. Replacement candidate `d7613ff7...` has now passed
  actual reviewed Build Plan admission at 11:50 UTC:
  `sha256:8a19f9094c304872c8f401126cc6d278811fe43fd6e90e98ffc6a1d450b3f432`.
  Exact artifact approval, deployment preflight and new-source fresh-install
  planning remain required; this Build-only Plan does not authorize Execute.
  Its subsequent Build failures exposed the metadata-version correction on M5.1.
  New `c9fec9e2...` Package/Prepare and genuine exact-source review pass.
  The reviewer independently checked all bindings/the two-file delta, API pins,
  source parsing and all 18 synthetic metadata regressions, with no significant
  findings. Supplied complete suites/Prepare/live readback were not rerun by
  that reviewer. Fresh actual Plan and all downstream gates remain required.
  Fresh actual `a3cb5183...` Plan admission and its saved binding checks now pass
  for that reviewed source. It permits Build only; artifact-bound execution and
  fresh-environment planning remain open.
  Historical verification 2026-09-22: corrected q5b preparation/validation completed before exact
  Plan acceptance and Apply. Ownership `912b63ad-5b38-4fcd-b528-f898c013685e`,
  Plan `sha256:64a2c5a579f89246fa9f0648f3593b871f30cb6cd865305004a70ac94695ffcd`
  binds the corrected source, separate namespace and reviewed configuration.
  Actor/tenant/subscription, scoped deployment/RBAC authority, regional capacity,
  inherited policy, first-party manager authority and Agent 365/Purview-for-agents
  licensing were read back. Actual allocation exercised private SQL, Windows B2,
  immutable ACR builds and the exact managed-identity resource roles.
  The earlier MFA blocker was resolved through the user-approved narrow policy
  and actual sign-in; existing policy fingerprints were preserved. A later Graph
  CAE session refresh used the same administrator without requesting the password
  or changing authentication policy.
  The existing operational plan retains regional/SKU retail inputs, variable
  charges, rollback/recovery limits and the user's no-cost-ceiling authorization.
  Both q5/q5b use S0 Content Safety, preserving the future M6 F0 choice.
  A fresh corrected-source M6 read-only Plan compiled all 12 templates and
  predicted eight foundation Creates with no deletions:
  `sha256:b4c605cf8ffeb7a45719fe18581adfca8bd8015df8076d51ac5b836f0a174872`.
  No M6 Plan was accepted, its steps remain empty and independent readback
  confirmed its group absent. Revalidate time-bound capacity/authority before
  execution; What-If does not authorize the separate imperative operations.
- [ ] **M5.6** Synchronize all project documents, directives, continuation state,
  memory and applicable configuration contracts; pass independent release review.
  Current source-only follow-up approves exact `7e18c7d4...` with no significant
  findings after independently verified bindings, six-file delta, actual
  read-only consumers and 65 passing StrictMode cases. Reboot continuation,
  current Build Plan admission and its failed pre-action Build are recorded
  without checking off unfinished artifact/hosted/final-review gates.
  Reboot checkpoint validation passes: retained candidate/Plan/review integrity,
  released local execution lock, 37 documentation-validator self-tests, and
  structural checks over 963 stable authored inputs, 27 Markdown files,
  336 local links, 15 anchors, 427 OpenAPI references and 48 operations.
  Whitespace checks pass; provider/runtime and complete semantic-review
  exclusions still apply. This does not close M5.6.
  Reopened 2026-09-24 for the full-stack novice-flow candidate: current structural
  checks pass. Genuine GPT-6 Astra source review approved exact candidate
  `f481e7f7...` / content source `121b6c14...`, with no significant findings;
  invocation and returned harness metadata establish the model, not a reviewer
  self-attestation. The reviewer rechecked provenance, all 671 non-null original
  hashes, 723 content/45 verifier inputs, 34 project literals, 48 PowerShell parses
  and bounded synthetic admission/revision/worker probes. Supplied suite/browser/
  Prepare results were not rerun. Live diagnosis, artifacts, deployment and
  provider acceptance were excluded. Final whole-project semantic/evidence
  synchronization and release qualification remain incomplete.
  Subsequent genuine source-only follow-up approved replacement `d7613ff7...` /
  content source `72ccd87b...`, without relabeling the earlier approval. Exact
  provenance/caller bindings and the single packaged-file delta were rechecked;
  12 sanitizer probes, synthetic frozen-core propagation and three source parses
  passed. No provider calls or artifact/deployment acceptance were claimed.
  Genuine source-only follow-up now approves `d9c98751...` / content source
  `d211d329...`, with no significant findings. The harness again identifies
  GPT-6 Astra. The reviewer independently verifies the exact five-file delta,
  all 723 source/45 caller-verifier inputs and ARM/canonical-binding boundaries;
  92 StrictMode Pester cases and 24 finite private-observer cases pass. The latter
  directly invoke existing compiled tests with portable-PDB source checksums
  and source/assembly byte guards, not a new build. Complete-suite, Prepare,
  SQL and live-readback evidence remains supplied, not independently rerun.
  New Plan/artifact/deployment approval and final whole-project release review
  remain separate and incomplete.
  The blocked handoff now distinguishes passing source review from rejected live
  admission and the completed, bounded governance lookup. Current read-only
  structural checks pass for 27 Markdown files, 332 local links, 13 anchors,
  427 OpenAPI references and 48 operations, plus all 37 validator self-tests.
  All 963 authored inputs remain stable during the structural run; its explicit
  provider/runtime and full semantic-review exclusions remain in force. This is
  partial synchronization evidence, not completion of M5.6.
  Historical verification 2026-09-22: all 27 authored Markdown documents, including every README,
  architecture/API/UX/operator guide, directives, memory, continuation and
  operational plan, were reviewed and synchronized with corrected q5b evidence.
  Schema admission, deprecated API response metadata and stale UX wording were
  repaired before the corrected freeze. Rerunnable structural validation passes
  309 local links, six anchors, 427 OpenAPI references and 48 operations, including
  actual-loader supplemental GUID checks; all 37 validator self-tests pass.
  Independent corrected-source/artifact follow-ups and the final whole-project
  semantic/evidence review found no significant remaining findings. Review
  reconciled the exact runtime/package, post-restoration Verify and telemetry
  evidence without claiming unrun provider acceptance.
  Tracked diff and all 78 untracked authored text-file whitespace checks pass.
  Owned short-path source copies, Windows scan extractions and 48 expanded Linux
  layer trees were removed; compact evidence, immutable blobs, source archives,
  actual packages and accepted snapshots were retained. Both historical and
  corrected source/package hashes were reverified after cleanup; current
  deployment input fingerprint remains `e03180c2...` without receipt relabeling.
  M5 was closed for that original release. Every M6 item remains unchecked;
  its Plan is unaccepted and target absent. Both qualification environments
  remain retained/billable; no commit or push was made.

## M6 — Fresh hosted product acceptance

The fresh M6 target is still undeployed. After M5 closure, the user separately
requested live simulator and browser checks on their existing q5b registration.
The observations below are bounded supplemental evidence, not acceptance of a
fresh M6 deployment or of untested registrations, policies and recovery paths.

- [ ] **M6.1** Deploy the reviewed candidate through the canonical installer into
  the pinned subscription and verify exact resource, identity and endpoint bindings.
- [ ] **M6.2** Complete real Chrome sign-in and onboarding with registrations that
  exercise new/reused blueprints, distinct child identities and credential lifecycle.
  Supplemental observation 2026-09-22: the user-created `ktx-v2-agent-01` on q5b
  is Active; installed Chrome shows its matching Registry entry and child identity
  `5654869d-9b6e-4db8-8253-9000999858cb`. The existing first-registration verifier
  issued and revoked only its own temporary key, then independently proved its
  temporary delegated grant, principal and active application absent. The user's
  key and registration were not rotated/recreated. This does not cover the full
  new/reused-blueprint or credential-lifecycle scenario set.
- [ ] **M6.3** Send complete external-agent interactions and verify downstream
  Agent 365 attribution and each selected telemetry destination.
  Supplemental q5b run 2026-09-22 10:06-10:08 UTC: the freshly rebuilt existing
  simulator sent one benign evaluation, activity and receipt-bound interaction.
  Browser acceptance found one active user/session in the exact M365 agent's
  Activity tab, four Purview AI activities and the same four Defender
  `CloudAppEvents` rows: two InvokeAgent and two InferenceCall, at 10:08 UTC.
  Exact agent/participant identity and shared report IDs were reconciled across
  the two portals; HTTP 202/200 alone was not used as downstream proof.
  Azure Monitor's sanitized activity mirror was observed, but its interaction
  mirror was not confirmed in the bounded readback. Complete destination-specific
  delivery and the remaining M6 scenarios are still unaccepted.
- [ ] **M6.4** Demonstrate Prompt Shields allow/block behavior for enabled agents.
  Supplemental q5b run 2026-09-22: the benign prompt was Allowed; the synthetic
  injection returned HTTP 403 and `PROMPT_BLOCKED_BY_PROMPT_SHIELD`. Actual
  Content Safety calls and Gateway request telemetry carry the exact agent and
  correlation bindings. The blocked correlation is
  `69ada6e1-11fd-4002-b123-8378a84f131b`.
  Defender hunting at 10:35:51 UTC found four positive-control activity rows but
  zero matching protection behaviors or alert metadata/evidence in the explicitly
  queried BehaviorInfo, BehaviorEntities, AlertInfo and AlertEvidence tables.
  Security for AI was Enabled and the Microsoft 365 connector Connected.
  Sentinel's browser workspace view, explicitly filtered to lab-02, showed no
  connected workspaces; exact Gateway-workspace ARM readback returned Sentinel
  NotFound. The block works, but downstream security-event/alert delivery was not
  demonstrated. No connector, rule, protection toggle or tenant policy was changed.
- [ ] **M6.5** Demonstrate Purview configuration and approved benign/sensitive
  runtime behavior for the selected shared policies; confirm truthful readiness.
  Supplemental q5b run 2026-09-22: DSPM > AI observability > Activity explorer >
  AI activities displayed the matching simulator records. Gateway Purview was
  Off for this run, and the Agent 365 exporter sends redacted message content.
  Inspected inference/invocation detail panes displayed "Related activity not
  found"; full prompt/response display was not verified. Activity visibility is
  not sensitive-data classification or DLP enforcement. No policy-mode or approved
  sensitive-sample case was run, and this item remains unchecked.
  Connection attempt blocked 2026-09-22: the downloaded companion matched the
  qualified bytes but was NotSigned and Internet-zone marked. Read-only checks
  found effective RemoteSigned at CurrentUser/LocalMachine; MachinePolicy and
  UserPolicy were Undefined, so an organization-wide Group Policy block was not
  established. PowerShell refused the script before execution. The supplied
  launch authorization expired at 11:28:55 UTC. Resume only through an approved
  trusted-signed distribution or authorized administration environment, followed
  by current operation readback and a fresh reviewed launch when required.
  No execution-policy override, origin-marker removal or expiry edit was attempted.
  UI recovery correction 2026-09-22: reproduced the separate website dead end
  after expiry, fixed it, and passed component plus real Chrome regression
  checks. The validated same-target Admin UI-only upgrade was accepted as
  `sha256:d278be419bcd3efe11e865308ed923860b95f52c7553b7c907e4e08a368b50e1`;
  ACR `de6` and ARM deployment succeeded with UI digest
  `sha256:e4500a152cc198db4bcbad65b4d7c2e8ec41e94f8412d9742863cfd386f712a0`.
  The original post-check incorrectly rejected Healthy RunningAtMaxScale.
  Original tool/receipt bytes were retained; a separately source-bound read-only
  follow-up verified the exact UI and unchanged API/worker/queue/bootstrap
  invariants without another deployment. Seventeen tool regression cases pass.
  Real Chrome now enables Review connection refresh and obtains the correct
  server review; that test review was cancelled before starting another timed
  launch. The website dead end is fixed. Tenant connection, client script trust
  and provider behavior remain separate unaccepted conditions.
  Supplemental prerequisite repair 2026-09-23: the user's exact Security &
  Compliance reference registration passed readback at 06:09 UTC with one create,
  no role/policy writes and unchanged unrelated references. A separately
  identified Gateway app-identity read passed at 06:26 UTC with 354 definitions,
  exact evidence bindings and remote exit zero. An earlier uncaptured diagnostic
  remains unconfirmed rather than being relabeled as success. The user's later
  fresh connection completed at 06:50 UTC with 354 definitions. The first-run
  UX correction and bounded hosted readback are recorded under M4.3; readiness
  expiry does not invalidate that historical completion. No DLP configuration
  or sensitive-sample enforcement was performed; this item remains unchecked.
  Guided-outcome follow-up 2026-09-23: de9 and 25 authenticated read-only checks
  verify explained historical/expired readiness and actionable onward recovery.
  M4.3/M4.7/M4.8 record the complete local UI/design acceptance. No Purview policy
  or sample was submitted for this follow-up; this provider item stays unchecked.
- [ ] **M6.6** Verify restart/reopen, actionable failures, role-appropriate access
  and operational recovery without repeating uncertain mutations.
- [ ] **M6.7** Reconcile the complete deployed candidate with every checklist item;
  resolve any newly invalidated acceptance conditions before final closure.
- [ ] **M6.8** Synchronize all project documents, directives, continuation state,
  memory and applicable configuration contracts; pass final independent review.
