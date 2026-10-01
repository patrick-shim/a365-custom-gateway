# Offline Admin UI regression tests

Run from the repository root with the SDK selected by `global.json`:

```powershell
dotnet restore .\tests\Gateway.AdminUi.Tests\Gateway.AdminUi.Tests.csproj --disable-parallel
dotnet build .\tests\Gateway.AdminUi.Tests\Gateway.AdminUi.Tests.csproj --no-restore --configuration Debug -m:1
dotnet test .\tests\Gateway.AdminUi.Tests\Gateway.AdminUi.Tests.csproj --no-build --no-restore --configuration Debug
```

## Fixture boundaries

- bUnit renders the production Getting started, Overview, registration, key
  handoff, operation, agent list/details, focused Settings tasks, shared policy
  editor, protection snapshots and runtime panel/report/status components.
  These commands do not start an app host, browser, provider endpoint or
  authenticated tenant session.
- `ScriptedGatewayApi` permits only explicitly queued API invocations. Unexpected
  calls are recorded and throw, even if a component catches the exception.
  Completion assertions reject unused or unexpected calls. It has no real API
  client fallback.
- The default HTTP client, named client factory and access-token provider deny
  network/authentication attempts. Guard tests explicitly exercise these failures,
  including requests aimed at Microsoft providers and managed-identity metadata.
  Package restore is distinct from offline test execution.
- Pending responses use completion sources, not sleeps. Fixed synthetic identity
  and commitment values provide the protection context; unavailable/available
  fixtures do not depend on a short wall-clock timing window. An injected
  `FakeTimeProvider` exercises the operation page's exact five-minute polling bound.
  Protection cases also exercise review/inventory/readiness expiry at equality
  and the runtime interop budget without sleeping.
- `PrivateSampleRuntime` routes only the private-sample module import to finite
  `ScriptedJsObject` instances. `prepare` returns commitment metadata, not sample
  text. Unscripted `execute` calls throw. Cleanup calls have a bounded allowance.
  Ordinary Fluent UI display/focus interop uses bUnit's non-executing stubs.
- Role cases cover administrator/operator/auditor/support-reader visibility and
  permitted history/credential calls, not server-side authorization. Registration
  cases exercise reviewed choices, preserved unavailable On defaults, double
  submission, exact-ID recovery and key acknowledgement before Registry.
  Operation cases distinguish manual confirmation, circuit-bound automatic
  completion, consent challenges, unknown outcomes and stale/expired polling.
  Lifecycle cases cover replacement/revocation, guarded navigation, selected-agent
  binding and Gateway-only deletion. Stale protection versions or edited runtime
  samples still require fresh review/approval without executing a sample request.
- Shared-policy cases cover 1-100 distinct classifiers, explicit threshold bounds,
  all four modes, independent Prompt Shields, impact acknowledgment, current
  version binding and known-operation readback after an uncertain response.
  Companion cases cover exact actor/tenant/operation/generation/expiry, retained
  launch recovery and separate verification. Original connection and completion
  approval IDs deliberately differ. Tests cover original-ID retention before
  confirmation, lost completion responses, guarded Submitted-approval readback,
  mismatched references, failed retention and disposal during readback.
  `VerificationFailed` connection resources remain Failed even after their old
  expiry; operation failure references and explicit UTC times remain visible.
  First-run cases verify explicit per-file trust instructions and primary paste
  without a manually created file. Paste and optional upload share strict result
  checks, surrounding-whitespace handling, bounded input and context/expiry
  rejection. Editing/clearing discards approval; a newer paste supersedes a late
  file read. Interrupted file reads offer paste rather than a false success.
  A 354-definition result exceeds 32 KiB; only the Chrome fixture proves its
  actual Interactive Server transport, finite shared limit and keyboard/zoom
  behavior.
  Outcome cases cover purpose/limits/next actions, pending-to-terminal current
  state refresh, three-second observation, stop/resume, five-minute deadlines
  with noncooperating reads, route/disposal races, wrong-tenant and expired
  history, and invalid/missing/duplicate exact-profile references. Report-route
  cases reject late responses for a previous route, mismatched current tenant/
  profile evidence and contradictory enforcement metadata.
  Cross-task cases retain a policy blueprint error, return to a connection and
  verify both automatic and manual recovery using only that task's required
  reads. Actual parent expiry cases replace runtime readiness with an earlier
  deadline and verify the outcome/card change without rebinding private samples.
- List/Overview cases use scripted API pages and totals for forward/back
  navigation, combined filters, restart, stale-response suppression and unavailable
  counts. They do not prove SQL ordering/search; the unit and local SQL listing
  fixtures cover those implementation boundaries separately.
- These are component-state and callback tests. They do not prove Chrome behavior,
  JavaScript hashing/erasure, real focus trapping, visual/accessibility acceptance,
  authentication, backend confirmation enforcement, or live protection behavior.
  Browser execution of the actual components remains a separate verification
  surface; no browser command or successful browser run is implied by these tests.

No fixture establishes milestone completion or live acceptance. See the sole
completion record, [MILESTONES.md](../../MILESTONES.md).

## Actual-component Chrome journeys

The separate [BrowserHost](../Gateway.AdminUi.BrowserHost) renders the real
application, routes, components and static assets. Its production host startup,
deployment configuration and Entra authentication are not executed. Identity,
Gateway API responses and keys are synthetic, and unexpected API/HTTP/token
access fails closed. The M4 runtime client accepts only matching synthetic
commitments and never invokes a provider; raw sample text is not included in
fixture state, counters or reports.

The novice policy fixtures also hold a prerequisite read open and verify that
the Settings host disables its competing refresh/blueprint/cancel actions,
shows activity and preserves the child's context and unsaved name. Host busy
state must not feed the child's own read state back into its `Busy` parameter.
Disposal fixtures dispose the actual component tree and assert cancellation
before releasing a noncooperating late response.

Create a fresh source-bound build rather than running retained binaries:

```powershell
.\tests\Gateway.AdminUi.BrowserHost\Build-BrowserHost.ps1 -Verify -KeepBuild
dotnet '<printed fixture DLL>' --port 0 --scenario empty --role Administrator
```

Keep that process running. In another terminal, use the printed loopback URL:

```powershell
node .\tools\Test-M3Browser.cjs --origin '<printed loopback URL>' --playwright '<installed Playwright package directory>' --chrome '<installed Google Chrome executable>'
```

The [driver](../../tools/Test-M3Browser.cjs) rejects nonlocal traffic, waits for
the real renderer interactivity marker, checks actual page transitions and
mutation counters, and exercises role boundaries, key handoff, unknown outcomes,
keyboard use, narrow layouts and actual Chrome 200% page zoom. Clipboard success
and denial use controlled browser API fixtures; no real credential or user's
clipboard is used. Fixture resets close the old document first.

For protection journeys, start the same fresh fixture DLL with `--https`:

```powershell
dotnet '<printed fixture DLL>' --https --port 0 --scenario m4-ready --role Administrator
```

The READY line supplies both the HTTPS loopback URL and its public certificate
path. The fixture generates a process-owned certificate without changing a
machine/user trust store or authoring a private-key file. Windows imports the
generated certificate through its key provider so Schannel can use it.
Trust only that public certificate in the Node test process:

```powershell
$previousCa = $env:NODE_EXTRA_CA_CERTS
try {
    $env:NODE_EXTRA_CA_CERTS = '<printed publicCertificatePath>'
    node .\tools\Test-M4Browser.cjs --origin '<printed HTTPS loopback URL>' --playwright '<installed Playwright package directory>' --chrome '<installed Google Chrome executable>'
} finally {
    $env:NODE_EXTRA_CA_CERTS = $previousCa
}
```

The M4 driver exercises the real private JavaScript sample flow, production HTTPS
portal and antiforgery checks, using only the synthetic backend. It includes
role/mode layouts, companion reopens and wrong evidence, primary paste of 354
synthetic definitions above 32 KiB, optional upload, cleared-input review
invalidation, trust-command copy/fallback, and keyboard access to the upload
disclosure. Wait for server-rendered modal dismissal before editing a background
field; Escape alone does not prove the modal finished closing. It also covers
policy conflict/unknown recovery, sample approval/erasure, safe reports, narrow layouts and actual 200%
zoom. A deliberately lost runtime response may produce one explicitly matched
fixture HTTP 502 console diagnostic; unexpected console/script errors still fail.
No fake UI callback or role selector establishes server/provider authorization.
The expired-connection fixture additionally verifies that a new reviewed
authorization produces a different operation and a usable new command, while
the expired command, paste field and upload remain unavailable.
Completion checks require the original connection ID before dispatch, after
acceptance, on reload and after lost responses. Opening an older completion
approval link follows readback without another POST. Pending/unknown completion
hides the helper, while genuine provider failure shows Failed and its bounded
reference rather than success or another administrator handoff.
The completion journey must click **Go to companion result** before
paste/review/submit without reloading afterward. It verifies the original ID,
separate approval and one completion, not just the link in isolation. Shared
recovery checks accept a changed scroll fragment but reject origin/path,
non-recovery query context, credential-bearing targets and invalid/duplicate
recovery IDs. They also preserve registration recovery and Blazor history state.
Component tests cover missing acknowledgment, JavaScript failure, disconnection
and timeout with explicit no-dispatch guidance, preserved completion evidence and
no raw diagnostic text.

Novice-flow regressions cover the ordered setup navigation, count-only connection
inventory, selected-type defaults and edited reselection, editor/library ordering,
actual edit focus, and the meaningful separate collection selector. Header and
dialog activity distinguish current work from saved status and support reduced
motion. Recovery keeps exact operation/profile binding and newly reviewed current
inventory separate from GET-only status reads. SQL administration and native
provider fixtures verify the corresponding accepted-binding and read-only
reconciliation boundaries; browser fixture success does not substitute for them.

The complete continuation journey clicks from independently verified connection
to a reviewed shared policy, automatic policy completion, exact-profile runtime
testing, the approved result and agents. It asserts one explicitly confirmed
operation at each mutation boundary and no automatic change to an agent's Off
choice. Technical details are collapsed but their skipped-step explanations are
inspectable. Real fragment links must remain on the current task/query rather
than resolving through the application's base URL. Responsive and actual-200%
checks inspect outcome copy, action visibility, keyboard use and the clipped
screen-reader announcement. Synthetic fixture controls wait for accepted state,
not only an incremented API-dispatch counter.

The actual sample module also has a bounded transport-only check:

```powershell
node .\tools\Test-M4RuntimeProtocol.cjs
```

That command exercises exact UTF-8 byte bounds, commitments, batching, private
interop metadata, URL retention, one-POST behavior and disposal with synthetic
in-memory transports. It does not replace the real Chrome or backend tests.

Stop the owned host gracefully with Ctrl+C after validation (the driver-control
API also exposes a guarded `POST /__fixture/shutdown`), then remove only its printed, uniquely owned
`.work` directory. The driver removes its temporary Chrome profile and leaves
synthetic screenshots in its printed `.test-work` directory for visual review;
remove that named directory when review is finished. These checks establish UI
behavior with local fixtures, not live identity/provider or release acceptance.

For component tests, set `AdminUiFixture.Rendering` before rendering to exercise
static or interactive behavior. The fixture applies `RendererInfo` at first
render, after clock/JavaScript services have been customized; resolving the
renderer earlier freezes bUnit's service registration.

The separate [UX design prototype](../../docs/ux/README.md) demonstrates design
fixtures, not these production components. Its checks do not substitute for
production browser journeys, API authorization or live acceptance. Use the
design's stable scenario IDs when adding M3/M4 component regressions.
