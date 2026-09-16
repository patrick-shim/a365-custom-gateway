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
- Use **Chrome**, through the installed browser extension, for browser work.
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

- [ ] **M1.1** Complete the remaining file-by-file source review and record the
  current journeys and invariants in the existing product/architecture guides.
- [ ] **M1.2** Establish a complete source baseline including untracked authored
  files and required build inputs, excluding generated output from source delivery.
- [ ] **M1.3** Re-establish the minimum missing Setup, migration, verification and
  test tooling needed by the retained projects; validate their references and
  entry points without relying on historical environment artifacts.
- [ ] **M1.4** Build the retained solution from a clean source copy with the pinned
  toolchain and identify reproducible local test commands.
- [ ] **M1.5** Add baseline tests for registration, credential lifecycle, prompt
  receipts, protection states and worker recovery; record actual passing outcomes.
- [ ] **M1.6** Establish deterministic UI/provider fixtures and a real SQL test
  path for transactional behavior; prove the local suite cannot call live providers.
- [ ] **M1.7** Synchronize all project documents, directives, continuation state,
  memory and applicable configuration contracts; pass a fresh consistency review.

## M2 — User journeys, language and acceptance design

- [ ] **M2.1** Define administrator, operator, auditor, support-reader and external
  developer journeys with entry point, decisions, outcomes and recovery actions.
- [ ] **M2.2** Define shared wording for installed, configured, active, off,
  simulation, verifying, enforcing, unavailable and action-required states.
- [ ] **M2.3** Produce reviewable screen layouts and exact copy for onboarding,
  registration, credential handoff, operations and protection tasks.
- [ ] **M2.4** Exercise the proposed flow in Chrome with representative empty,
  loading, success, error and restricted-role fixtures, keyboard navigation and
  narrow layouts; resolve the identified usability issues.
- [ ] **M2.5** Bind each proposed feature change to a concrete acceptance scenario
  and preserve existing identity, confirmation, receipt and recovery contracts.
- [ ] **M2.6** Synchronize all project documents, directives, continuation state,
  memory and applicable configuration contracts; pass a fresh consistency review.

## M3 — Core onboarding and everyday management

- [ ] **M3.1** Implement clear getting-started navigation and copy; browser-verify
  the route from a new installation to first registration.
- [ ] **M3.2** Complete registration with both new and reused blueprints; test
  validation, double submission, defaults and an interrupted response.
- [ ] **M3.3** Implement a consistent endpoint/ID/key handoff and non-secret sample
  command; test one-time display, copy feedback, navigation and lost-key recovery.
- [ ] **M3.4** Improve provisioning progress and administrator handoff; test manual
  and permitted automatic completion, consent challenges, refresh and reopen.
- [ ] **M3.5** Verify the full sample gate through evaluation, model callback and
  ingestion; prove denied/stale/expired proof never starts or repeats generation.
- [ ] **M3.6** Correct agent cursor round-tripping, name/external-ID search,
  pagination and fleet totals; test more than 100 records and stable filtered pages.
- [ ] **M3.7** Verify credential replacement/revocation, enable/disable, audit and
  operation navigation, and truthful Gateway-only deletion wording.
- [ ] **M3.8** Pass focused regression tests, Chrome journey/accessibility checks
  and independent review for the complete core experience.
- [ ] **M3.9** Synchronize all project documents, directives, continuation state,
  memory and applicable configuration contracts; pass a fresh consistency review.

## M4 — Protection configuration and runtime verification

- [ ] **M4.1** Organize existing protection functions into focused optional tasks;
  verify a core-only registration has no misleading incomplete/error state.
- [ ] **M4.2** Unify registration/protection summaries across overview, list,
  details and Settings; distinguish requested configuration from effective behavior.
- [ ] **M4.3** Improve the Windows companion connection and inventory handoff;
  test cancellation, wrong tenant/account, stale inventory and reopening the task.
- [ ] **M4.4** Verify shared blueprint policy scope, multiple classifiers,
  thresholds, reviewed impact, concurrent edits and deferred new-blueprint binding.
- [ ] **M4.5** Verify all supported policy modes and independent Prompt Shields
  choices; preserve receipt invalidation when effective protection changes.
- [ ] **M4.6** Verify approved runtime sample review/execution/status, positive and
  negative behavior, expiry and unknown outcomes; preserve ephemeral sample handling.
- [ ] **M4.7** Pass focused tests, Chrome workflow/accessibility checks, API schema
  conformance and independent review of the protection experience.
- [ ] **M4.8** Synchronize all project documents, directives, continuation state,
  memory and applicable configuration contracts; pass a fresh consistency review.

## M5 — Release packaging and deployment readiness

- [ ] **M5.1** Build and test the exact candidate from a clean source copy; prove
  no dependency on old local checkpoints, binaries or unpublished working files.
- [ ] **M5.2** Validate API, Admin UI and worker containers plus the pinned Windows
  executor/package-publisher path from that candidate.
- [ ] **M5.3** Validate database initialization and applicable migrations using
  real SQL, including receipt consumption, concurrency, outbox and compatibility.
- [ ] **M5.4** Verify authorization boundaries, queue redelivery, uncertain provider
  outcomes, telemetry redaction and absence of secrets in release artifacts.
- [ ] **M5.5** Prepare a concrete fresh deployment plan in the pinned subscription:
  region, resources, identities, cost/quota, permissions, source and rollback bounds.
- [ ] **M5.6** Synchronize all project documents, directives, continuation state,
  memory and applicable configuration contracts; pass independent release review.

## M6 — Fresh hosted product acceptance

- [ ] **M6.1** Deploy the reviewed candidate through the canonical installer into
  the pinned subscription and verify exact resource, identity and endpoint bindings.
- [ ] **M6.2** Complete real Chrome sign-in and onboarding with registrations that
  exercise new/reused blueprints, distinct child identities and credential lifecycle.
- [ ] **M6.3** Send complete external-agent interactions and verify downstream
  Agent 365 attribution and each selected telemetry destination.
- [ ] **M6.4** Demonstrate Prompt Shields allow/block behavior for enabled agents.
- [ ] **M6.5** Demonstrate Purview configuration and approved benign/sensitive
  runtime behavior for the selected shared policies; confirm truthful readiness.
- [ ] **M6.6** Verify restart/reopen, actionable failures, role-appropriate access
  and operational recovery without repeating uncertain mutations.
- [ ] **M6.7** Reconcile the complete deployed candidate with every checklist item;
  resolve any newly invalidated acceptance conditions before final closure.
- [ ] **M6.8** Synchronize all project documents, directives, continuation state,
  memory and applicable configuration contracts; pass final independent review.
