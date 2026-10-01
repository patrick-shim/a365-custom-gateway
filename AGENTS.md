# Project agent directives

## Read first

Read [MILESTONES.md](MILESTONES.md), [project state](docs/project-state.md),
[repository memory](MEMORY.md), and the relevant source before changing the project.
The milestone checklist is the sole project completion record.

## User instructions

- Treat the retained application as a working baseline. Improve UX flow, wording
  and selected features through the milestone plan.
- The user deliberately deleted supporting files and Azure resources. Do not use
  old deployment prose or incident-specific repair scripts as current state.
- Use the supplied temporary administrator credential or its authenticated
  session. Do not request it again. The password belongs only in the authorized
  authentication flow, never in files, logs, command arguments or documentation.
  Its source is the user's credential message in this task on 2026-09-16; consult
  existing task history when context has been compacted. A genuine MFA challenge
  is a separate user action, not a reason to request the password again.
- Pin all project Azure operations to tenant
  `ff8b1e46-ff0f-4bc2-ab02-caf2b92da496` and subscription
  `internal-security-lab-02` / `6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`.
  Pass the subscription explicitly to Azure resource commands.
- Use installed Chrome or Edge for browser interaction and testing. Direct
  browser control is authorized by the user as of 2026-09-19; the extension is
  optional. Use an isolated browser profile for synthetic local fixture checks.
- Respect authorization already given in the conversation. Do not add repeated
  permission prompts based solely on historical repository instructions.

## Work and acceptance

- Preserve current untracked authored source. Generated bin/obj output is not a
  reproducible source baseline or test result.
- Implement bounded changes with acceptance scenarios. Protect identity binding,
  delegated Registry completion, receipt validity, shared policy scope, durable
  recovery and accurate status reporting.
- Check off a task only after its own implementation and verification pass.
  Record its brief verification basis on that item in MILESTONES.md.
- Keep failed, blocked, partial and unrun tasks unchecked. Reopen invalidated checks.
- Do not create competing status/evidence checklists or reuse historical pass counts.
- At every milestone closure review and synchronize ALL project documentation,
  READMEs, architecture/API guides, agent directives, continuation state, memory,
  and relevant configuration/schema contracts. Validate links and check the diff.
- A milestone's final synchronization is required before starting its dependent
  milestone. Keep current behavior, future acceptance criteria and actual verified
  completion distinct in every document.
- Runtime source-bound checkpoints/receipts remain application operational state;
  they do not establish milestone completion by themselves.
- Subagents must use scoped file ownership, keep the same source of truth, avoid
  credentials in delegation messages, and report actual verification limits.

## UX design and implementation

- Read the [UX design package](docs/ux/README.md) before M3/M4 UI changes. Keep its
  journeys, state wording, exact screen copy, prototype and acceptance scenarios
  consistent with one another and the implemented API permissions.
- The prototype is a separate synthetic design fixture. It never authenticates,
  loads deployment configuration or executes Gateway/provider mutations. A role
  selector demonstrates visibility; it does not verify server authorization.
- Preserve the immediate one-time key handoff before Registry completion. Keep
  registration, configured policy, current protection and telemetry delivery
  distinct. Unknown external outcomes require readback, not another create.
- Browser design checks do not close M3/M4 production behavior or M5/M6 release
  and provider acceptance. Keep proposed features explicit until implemented.
- A protection task must explain what happened, why, what remains unverified and
  the next permitted action. A Completed/Skipped technical log is not the user
  journey. Observe progress read-only, preserve exact context, and never silently
  confirm, replay or enable protection to make the flow appear complete.

## Local baseline learnings

- Use [the local baseline runner](tools/Test-LocalBaseline.ps1) for a clean
  authored-source copy and allowlisted tests; `-IncludeSql` explicitly adds the
  real SQL path. Empty/skipped results, old bin/obj files and historical deployment
  artifacts are not baseline evidence.
- Provider/UI fixtures must use terminal deny-by-default transports and synthetic
  credentials, not production host configuration or ambient Azure authentication.
  Do not discover tests by executing every script under operations.
- On Windows ARM64, resolving a named LocalDB instance through SqlClient can fail
  when its user-instance DLL is x64. Reuse the
  [owned LocalDB fixture](tests/Gateway.TestSupport/LocalSqlInstance.cs), which
  reads the exact local named pipe from the instance it just created; never fall
  back to remote SQL, a shared instance or an arbitrary supplied pipe.
- LocalDB tests exercise the current EF schema and real transactions. They do not
  validate Azure identity/private networking or the complete migration/receipt
  protocol, which retain their separate release and live acceptance.

## Learnings

- Production browser checks use [the actual-component fixture](tests/Gateway.AdminUi.BrowserHost)
  and [its Chrome driver](tools/Test-M3Browser.cjs), not the M2 prototype. The
  fixture owns a fresh source build and synthetic identity/API; its success is
  not evidence of real Entra or provider authorization.
- Keep `Routes` and `HeadOutlet` interactive together when relying on
  `NavigationLock`. Static enhanced-navigation links bypassed an unsaved-key
  warning even though component tests passed; verify a real link click in Chrome.
- A fragment-only link such as `#profile-runtime-...` resolves through the Blazor
  base URL and can send a nested task to Home. Build it on the current path and
  query, preserving the exact profile/operation, and click it in Chrome.
  Screen-reader-only text needs actual scoped clipping CSS, not an assumed
  global `sr-only` class.
- Same-page scrolling can change the browser fragment without updating
  `NavigationManager.Uri`. Recovery retention must preserve the browser fragment
  while still checking origin, path, non-recovery query context and the exact
  recovery ID; never remove the positive acknowledgment barrier. Test shortcut,
  paste, review and submit as one uninterrupted Chrome journey.
- Blazor caches resolved JavaScript functions after their first interop use.
  Install test instrumentation before that first call in a fresh document;
  replacing the global function afterward may not intercept it. Expected
  pre-dispatch retention failures need explicit no-request guidance and safe
  operation-ID/error-type logging, not raw evidence or exception messages.
- Disable editable prerendered controls until `RendererInfo.IsInteractive`.
  Render ARIA states as strings (`"true"`/`"false"`), not HTML boolean attributes.
  Tests set `AdminUiFixture.Rendering`; resolving bUnit's renderer before clock
  or JavaScript service customization freezes its service collection.
- A realistic companion result exceeds Blazor's default 32 KB inbound message
  limit. Keep the production host and actual-component fixture on the same finite
  transport limit, retain separate text/decoded limits, and test a 354-definition
  paste in Chrome; component tests cannot prove that transport works.
- A downloaded script blocked before execution cannot unblock itself. Explain the
  organization-permitted, exact-file trust step before the run command; never
  lower signing policy. Console result handoffs should support direct paste,
  with saved-file upload optional and the same validation on both paths.
- In Chrome tests, Escape dispatches asynchronous Blazor dialog dismissal.
  Wait for the dialog to disappear and the server-rendered cancellation state
  before editing its background fields; otherwise keyboard input can still be
  trapped. Wait on observable state, not a fixed delay.
- A mouse click followed by programmatic focus does not establish keyboard
  modality. Use real Tab/Enter navigation before asserting `:focus-visible` on
  a replacement Stop/Resume control; do not force production focus styles to
  satisfy a pointer-driven test.
- Preserve a requested On default when prerequisites are unavailable. Block
  submission until prerequisites are restored or the user explicitly selects
  Off; availability must not silently rewrite the user's configured choice.
- Await client acknowledgment of non-secret recovery state before dispatching
  creation. Blazor Server `NavigateTo` alone is fire-and-forget, so calling it
  immediately before POST does not prove the browser retained the recovery ID.
- Ordinary protection starts use the review token ID as the durable operation ID.
  Companion completion has a separate approval ID but resumes the reviewed
  `SourceOperationId`. Retain and expect the original connection ID before
  confirmation/mutation; recover unknown results by GET, never another create.
  An old Submitted completion approval can reference that original operation;
  validate both records' identity/type/target binding before following it.
- Model worker contracts faithfully in fixtures: a connection can be
  `VerificationFailed` while a nonretryable verification operation and its active
  zero-based step are `RequiresManualIntervention`. Later steps stay Pending and
  unrun; the UI translates the failure status separately. Exercise distinct
  completion IDs and cleared authority lifetimes, not just a callout's wording.
- Readiness snapshots carry the earliest known connection/inventory/behavior
  expiry. Expiry equality invalidates a current badge; that bound never grants
  authority or prevents an earlier server-side context change. Operation status
  and saved profile status are different fields.
- A terminal operation GET must refresh its current connection/inventory/profile
  before offering onward actions; failed or deadline-interrupted refresh cannot
  reuse an earlier badge. Child runtime-readiness updates may refresh a parent
  summary without rebinding an active private-sample session.
- Use the same task-scoped predicates for selecting reads and deciding whether
  refresh succeeded. An old policy-task blueprint error must not prevent a
  connection-task readback from recovering when blueprint discovery is not read.
- When a runtime callback replaces the readiness used by a parent outcome/card,
  reschedule that parent's expiry boundary with the replacement deadline too.
  Keeping only the original profile's expiry can leave an Enforcing badge after
  its effective evidence expired. Keep the private sample context stable.
- Fixture API counters record dispatch, not committed state. Wait for explicit
  accepted state before advancing a synthetic worker. Policy saves/tests must
  preserve per-agent On/Off choices in fixtures as well as production.
- A renewed connection does not silently renew a saved profile's inventory
  binding. Existing-policy reconciliation can adopt a genuinely current
  generation only through a new exact review, confirmation and accepted
  transaction; preserve IDs/settings/agent choices and invalidate old runtime
  proof. Reconcile Microsoft objects by readback, never by another create.
- Within one native Purview invocation, validate all selected SITs against one
  fresh catalog and import only the commands that operation needs. Recheck
  expiry immediately before a write, including after update-target readback;
  preserve bounded read timeout/expiry diagnostics without treating unknown
  mutation outcomes as retryable reads.
- Use the [M4 Chrome driver](tools/Test-M4Browser.cjs) over the owned HTTPS fixture
  for private runtime samples. Its certificate is process-owned and its public
  PEM is trusted only by that test process, not installed globally. On Windows,
  Schannel needs the generated certificate imported through its key provider.
  Shut the fixture down gracefully to dispose its certificate.
- Razor string parameters require an expression marker: use
  `RegistrationStatus="@agent.Status"`, not the literal `"agent.Status"`. Check
  positive protection states on the actual parent pages as well as the isolated
  shared component, and visually inspect responsive report captions and buttons.
- Drive deadline cancellation with the injected `TimeProvider`, not a wall-clock
  `CancelAfter`. Bound awaited dependencies as well as signalling their tokens:
  a noncooperating provider must not extend the runtime request beyond its
  accepted deadline or trigger another sample submission.
- Treat an awaited browser-session creation as owned work even before its
  reference is assigned. Serialize initialization, recheck the captured UI
  context after each await, and erase/dispose late unpublished sessions after
  Close, disposal or a profile change. A null current reference does not prove
  there is no browser-held state.
- Source-copy tests can load multiple PowerShell modules with the same basename.
  Give a copied fixture module a unique name, import it with `-NoClobber`, and use
  that exact module for calls and mocks. Verify the caller's original exports
  still resolve after fixture cleanup; reimporting them would hide pollution.
- Capture `$?` immediately after invoking a bootstrap PowerShell script when
  propagating its success through the Windows launcher. `$LASTEXITCODE` may
  retain a handled native failure from inside a normally completed script.
- PowerShell localizes `ScriptStackTrace` separators and line labels; do not
  assume the English `function, path: line N` format. Retain bounded existing
  relative source-file/line coordinates through a failed child-process boundary,
  never raw provider output or a success marker from a nonzero exit. Use those
  coordinates to reproduce the smallest failing read rather than repeatedly
  running complete verification to recover discarded diagnostics.
- Pin generic ARM metadata reads to the reviewed resource API versions rather
  than letting `az resource show` select the newest advertised version. A
  registered provider can return `NoRegisteredProviderFound` when that version
  is unavailable in the resource's region; compare the same exact read with
  the deployed template version before changing registration or governance.
- Compare live ARM resource identities with ordinal case-insensitive equality:
  Azure can return `containerapps` for a requested `containerApps` resource.
  Apply the same semantics to child membership and duplicate detection across
  local and private observers; never deactivate an admitted sentinel merely
  because its ID spelling differs. Do not normalize signed Plan/receipt bytes,
  source/image hashes, principal bindings, phases or health states to pass.
- A successful SKU restoration does not prove that it will persist. If drift
  returns, correlate Resource Graph property changes with the exact Activity Log
  correlation ID; an empty resource-ID-filtered query does not prove no change.
  For cross-tenant automation, resolve its claims' application ID in the pinned
  project tenant rather than assuming its caller object ID belongs there.
  Preserve the accepted baseline and governance; do not loop rescaling or invent
  bypass tags/permissions to force a release through.
- Extract immutable candidates into a short owned path for nested Windows SQL
  baseline runs. Native SqlClient DLL loading can exceed the Windows path limit
  even when managed compilation succeeds; do not change global OS settings or
  replace the owned LocalDB fixture to hide that failure.
- A scanner's zero exit code does not prove every file was read. Gitleaks archive
  autodetection can misclassify PE DLLs as Brotli and still exit zero; reject error
  diagnostics, extract verified archives explicitly and scan their ordinary files.
- Preserve UTC strings when loading probe receipts for KQL, for example with
  `ConvertFrom-Json -DateKind String`. Default PowerShell date conversion followed
  by interpolation can drop the offset and query a future local-time window.
- Require explicit remote probe output, not the `az containerapp exec` exit code.
  A cluster success message can accompany a failed child command. Use bounded
  console sessions, the official input framing and paced terminal-sized input;
  keep managed-identity tokens inside the exact caller container.
- Bootstrap marks the Windows executor Installed without claiming runtime
  readiness. Qualify `/health/ready` privately with the exact worker identity and
  expected package/source, and restore any temporary qualification scaling before
  final verification. This health proof is not Purview policy/provider acceptance.
- Full maintenance after a UI-only promotion must keep original ARM/image
  evidence separate from the freshly verified successor in every readback.
  `immutableImages` remains original; `deployedImages` uses the verified live UI,
  with unchanged API/worker expectations. Recheck predecessor bindings before and
  after complete verification; never relabel original state or old receipts.
- Container App revision `RunningAtMaxScale` is a normal running state, not an
  error or a health guarantee. Keep exact revision/image, health, replica count
  and probes, and independently require each actual replica to be `Running`,
  started and ready. Exercise the actual joint release gate: a passing promotion
  receipt must not bypass original worker environment preservation.
