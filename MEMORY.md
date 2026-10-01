# Repository memory

Durable project preferences; completion belongs only in [MILESTONES.md](MILESTONES.md).
Continuation context belongs in [docs/project-state.md](docs/project-state.md).

- The retained application works. The next work improves UX, wording and selected
  features while preserving existing contracts.
- Supporting files and Azure resources were deliberately deleted by the user.
- All Azure project resources use tenant `ff8b1e46-ff0f-4bc2-ab02-caf2b92da496`,
  subscription **internal-security-lab-02** (`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`).
- Use the temporary administrator credential already provided in the conversation
  or the authenticated session; do not ask for it again. The credential source is
  the user's message in this task on 2026-09-16. No password is stored here.
- Use installed Chrome or Edge. The user authorized direct browser control on
  2026-09-19; the extension is optional. Keep synthetic local checks in an isolated
  browser profile, separate from authenticated user sessions.
- The milestone task checkmarks are the only project acceptance record. An
  attempt, old result or operational receipt does not earn a checkmark.
- Every milestone includes a whole-project documentation/directive/state/memory
  synchronization and consistency review before closure.
- On 2026-09-22 the user authorized all resources needed to finish M5, without a
  cost ceiling. Keep qualification isolated in the pinned subscription, preserve
  unknown outcomes and unrelated resources, and complete M5 before starting M6.
- Local development uses [Test-LocalBaseline.ps1](tools/Test-LocalBaseline.ps1);
  real SQL is explicit with `-IncludeSql`, and provider fixtures never use ambient
  Azure credentials. Keep the isolation and ARM64 LocalDB guidance in
  [AGENTS.md](AGENTS.md) when extending the suite.
- The [UX design package](docs/ux/README.md) is the design reference for M3/M4:
  role journeys, shared state wording, screen copy and acceptance scenarios.
  Its local prototype uses synthetic fixtures and never represents live provider
  results or implemented production changes.
- Real-component browser checks use the isolated
  [BrowserHost](tests/Gateway.AdminUi.BrowserHost) and
  [M3](tools/Test-M3Browser.cjs) and [M4](tools/Test-M4Browser.cjs) Chrome drivers.
  M4 executes private sample flows through the real local HTTPS portal with a
  finite synthetic backend, never a live provider. Preserve the interactive-router,
  prerender, test-fixture and requested-default learnings in
  [AGENTS.md](AGENTS.md); local identity/API fixtures do not establish hosted
  Microsoft authorization or provider acceptance.
- A companion completion review authorizes continuation; it is not a new
  connection. Its approval ID differs from the original connection operation ID,
  which remains the browser's execution/recovery ID. Keep distinct IDs and actual
  resource status values in component and browser fixtures.
- Successful administrator sign-in and a classifier catalog do not transfer that
  sign-in to the Gateway. Independent verification uses the configured automation
  identity. Its Entra principal and its Security & Compliance reference are
  separate prerequisites; neither helper completion nor private health proves DLP.
- First-time companion guidance must show per-file download trust before
  execution and accept the console result directly, without requiring a manual
  text file. Keep paste/upload validation identical and verify a realistic large
  result through the actual bounded browser transport, not only component tests.
- Protection completion must explain the result, purpose, limits and exact next
  action, with bounded GET-only progress rather than a dead-end technical log.
  Refresh current readiness independently; Off and simulation are valid outcomes,
  and shared-policy work never silently enables an agent.
- The novice Purview journey is an ordered guide, not unexplained tabs. Show
  inventory count on connection, select SITs once in the policy editor, explain
  adjustable new-selection defaults, preserve draft/saved values, and show honest
  activity with a reduced-motion alternative. Blazor supports this flow; a
  framework rewrite is not a substitute for fixing workflow/provider defects.
- Renewing connection authority does not silently renew a saved policy.
  Newly reviewed reconciliation may bind unchanged settings to actual current
  inventory at acceptance, invalidate old proof and read existing Microsoft
  objects without replaying a create. Keep the exact-binding and bounded native
  read guidance in [AGENTS.md](AGENTS.md).
- Preserve nested-route fragment context and current-readiness/private-session
  ownership as described in [AGENTS.md](AGENTS.md). Test actual clickable
  continuation in Chrome, not only the presence of a next-step link.
- Browser/server scroll fragments can differ after a same-page shortcut.
  Keep recovery identity/context validation and positive acknowledgment, but
  preserve the browser fragment. The shortcut-to-submit regression and Blazor
  interop-cache instrumentation guidance in [AGENTS.md](AGENTS.md) prevent
  separate passing link/submission tests from hiding a broken combined journey.
- Refresh success must use the current task's read dependencies, not every
  retained error from another task. Replacement runtime readbacks must update
  parent expiry scheduling as well as visible state, without rebinding samples.
- Successive Admin UI-only upgrades retain the original bootstrap and prior
  upgrade receipts. The canonical tool freshly verifies the exact predecessor
  and binds it into the new Plan; an old Accepted post-check failure is not
  rewritten as success or recovered by replaying its deployment.
- Full source-only maintenance admits the exact originally accepted custom
  target, not an inferred conventional replacement. Preserve the original/live
  image distinction and revision-versus-replica readiness checks in
  [AGENTS.md](AGENTS.md); independently reverify UI predecessor history and
  original worker settings rather than weakening a failed release gate.
- An Azure provider-registration error does not by itself justify registration.
  Generic metadata verification uses reviewed explicit API versions; diagnose
  unsupported region/version separately from missing registration and preserve
  the exact ownership/type/source checks described in [AGENTS.md](AGENTS.md).
- Azure may change ARM ID casing between request and readback. Treat those
  identities and duplicate aliases consistently in both orchestration and
  private cutover observers, without rewriting signed bindings or weakening
  scope, provenance, readiness and no-replay checks; see [AGENTS.md](AGENTS.md).
- Recurring cloud drift can come from delegated governance automation, not the
  application or the user. Use the correlation/actor workflow in
  [AGENTS.md](AGENTS.md); preserve governance and accepted baseline evidence
  rather than repeatedly undoing the controller's changes.
- On 2026-09-25 KST the user explicitly approved Windows B1 when quota permits
  and directed continued M5 delivery. Honor that choice without requiring a B2
  governance exception. Accept an existing SKU change only through the reviewed
  maintenance request and live readback; keep original B2 receipts unchanged.
- After a reboot, resume from the exact candidate, review, Plan and action
  checkpoints in [project state](docs/project-state.md). Preserve failed
  attempts and recheck live authority; an admitted Plan does not replace a later
  failing execution-time baseline, and an empty action directory is not a
  successful build. Do not silently restart installation or provider mutations.
- Release qualification must bind a fresh authored-source archive and package,
  not reuse generated binaries. The [Windows package qualifier](tools/Test-PurviewPackage.ps1)
  uses an owned profile and synthetic authority for native and unauthenticated
  loopback checks. These checks do not qualify Linux images, live Entra
  authorization or the private Azure SQL initialization/receipt protocol.
- Qualify the exact package built and published by the canonical installer,
  even when an earlier local ZIP has the same source fingerprint. Keep the two
  content digests distinct. Private executor Ready must match the actual package
  and source and is still not Purview connection or policy enforcement evidence.
