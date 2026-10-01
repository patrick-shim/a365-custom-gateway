# User experience design

This is the design reference for the M3 core and M4 protection implementation.
The architecture/API guides describe the current
application and contract. The design and its synthetic prototype do not establish
a deployed environment or provider acceptance. Completion is recorded only in
[MILESTONES.md](../../MILESTONES.md).

## Design artifacts

| Question | Artifact |
|---|---|
| Who can do what, and what does each status mean? | [Journeys and language](journeys-and-language.md) |
| What should each screen show and say? | [Screen designs](screen-design.md) |
| What observable outcomes must implementation preserve? | [Acceptance scenarios](acceptance-scenarios.md) |
| How do the proposed screens behave together? | [Interactive prototype](prototype/index.html) |

The prototype uses synthetic fixtures and local assets. Its fixture controls are
review tools, not proposed product navigation or authorization. Changing a fixture
role does not sign in. Registration, deployment, policy changes and provider tests
are simulated. No Microsoft or Gateway service is contacted.

The design keeps credential handoff immediately after registration, separates
registration status from protection and telemetry, and makes shared blueprint
policy impact explicit. Operations remain linked to their agent or protection
task. The backend's role enforcement, reviewed confirmation, exact identity
bindings and uncertain-outcome recovery remain required implementation contracts.
For companion completion, the separate approval continues the original connection
operation. The design fixture keeps result submission and independent verification
visibly separate; neither means DLP is enabled. First-run guidance explains
download trust before execution, then uses direct result paste with optional
saved-file upload. The design fixture accepts only its synthetic example and
never reads a real companion file or authenticates.
Its hash-based navigation does not model the production browser-recovery
protocol. The real-component Chrome journey must click **Go to companion
result**, paste, review and submit without reloading after that shortcut;
checking the link and submission separately is insufficient.

## Guided protection continuation

[UX-34](acceptance-scenarios.md#ux-34--complete-the-novice-protection-journey)
defines the novice journey from connection to an explicit agent protection choice.
Each outcome answers **What happened**, **Why this matters**, **What remains**,
and **Next step**, before collapsed **Technical operation details**. Skipped
means not run, not passed. A completed connection verifies independent Gateway
app access and a current classifier inventory; it does not create a policy,
enable an agent or prove DLP blocking.

The explicit path is **Continue to shared policies** → choose the blueprint and
review exact classifiers, thresholds, mode and shared impact → **Continue to
behavior tests** for saved Enforce → approve a clean negative and intended-SIT
examples → **Continue to agents** → review that agent's choices. Onward policy
and runtime links retain the exact `profile` query value. Missing profiles never
fall back to the first returned profile. Off is a valid saved outcome with no
runtime test requirement; simulation remains non-blocking with optional
diagnostics. Collection and telemetry delivery are separate, not prerequisites
or implied outcomes of DLP setup.

The setup header is an ordered journey: **1 Connect tenant**, **2 Set shared
policy**, **3 Test behavior**, **4 Review agent choices**. Its highlight is the
current location, never a completion or protection claim. Revisiting an allowed
step is safe; unavailable prerequisites explain the next permitted action.
**Protection overview**, **Optional data collection**, and **Registration
defaults** are separate tools, not extra setup steps. Connection summarizes the
actual current inventory count; it does not ask for a classifier selection.
Select classifiers once in the shared-policy editor, then adjust their starting
thresholds and review the whole change.

### Framework decision

Retain interactive Blazor for this improvement. The reproduced problems are
workflow/state presentation and slow, freshness-bound provider reads, not a
demonstrated framework limit. Blazor supports event-driven busy states,
accessible CSS activity indicators, progressive disclosure, draft preservation
and explicit navigation. A React migration would still need the same server-side
authority, provider timing, one-time handoff and recovery contracts, while adding
migration risk. Reconsider the framework only if actual-component browser
acceptance demonstrates a remaining limitation; the synthetic prototype is not
evidence of production responsiveness.

The connection, policy and runtime task disclosures expose additional **design
only** states: pending, stopped, failed, unknown, read error, expired readiness
and unavailable prerequisites. Pending connection observation models three-second
GET-only reads of the original operation, stopping after five minutes until
explicitly resumed. **Stop automatic updates** pauses only observation;
**Resume automatic updates** reads the same operation within a fresh bounded
session. Terminal readback separately reloads current connection/inventory
context, which may already be expired despite Completed history. In the prototype
these are timed reads of in-memory fixtures, not network requests; a reviewer
explicitly supplies any terminal fixture result and current-context snapshot.
Completion never automatically navigates, reviews, configures or enables
anything. A fresh page load discards synthetic state; it does not demonstrate
production durable recovery.

## Review and validation

There are two separate browser paths. The M2 prototype below is a design fixture.
The [actual-component host](../../tests/Gateway.AdminUi.BrowserHost) and
[core Chrome driver](../../tools/Test-M3Browser.cjs) and
[protection Chrome driver](../../tools/Test-M4Browser.cjs) exercise the real
Blazor routes/components with synthetic identity and a terminal fake API.
They cover core registration, one-time handoff, navigation, recovery, roles,
listing, lifecycle, scoped policy review, companion recovery and approved sample
behavior. M4 uses an owned HTTPS fixture and the production portal/antiforgery
endpoints with a finite synthetic execution client. Neither path establishes live
authorization or provider results. Use the [Admin UI test guide](../../tests/Gateway.AdminUi.Tests/README.md)
for that host's clean build and run commands.

Use installed Chrome or Edge. The user authorized direct browser control on
2026-09-19; the extension is optional. From the repository root, start the local
review server with Node.js:

```powershell
node .\tools\UxPrototype.cjs --serve --port 0
```

Open the printed loopback URL in Chrome or Edge. Port `0` selects an available
local port; use `--port 4173` only when that fixed port is free. Stop the server
with Ctrl+C. The server serves only the three prototype assets on loopback;
it does not load application configuration. The Role and State selectors expose
the review fixtures. Follow
the screen designs for registration, key handoff, setup, policy and recovery
interactions; include keyboard-only use and narrow browser widths.

The [review harness](../../tools/UxPrototype.cjs) supports an isolated automated
session using an explicitly supplied installed Chrome executable and Playwright
package. It exercises every view, role and fixture state at desktop and narrow
widths, the keyboard-only registration/key/Registry handoff, and modal focus in
both directions. It also follows the complete clickable UX-34 protection journey,
including exact-profile navigation, explicit agent choice, Off/simulation,
safe recovery and deadline-bounded local observation. It selects actual 200%
page zoom in Chrome's Appearance
settings and checks the resulting layout and dialogs; CSS scaling or pinch zoom
does not substitute for that check. Actual execution belongs on the milestone
item, not in this guide.

```powershell
node .\tools\UxPrototype.cjs --check --playwright '<installed Playwright package directory>' --chrome '<installed Google Chrome executable>'
```

The check command starts its own task-owned loopback server, rejects nonlocal
requests and writes synthetic screenshots under the ignored `.test-work`
directory. Its uniquely owned Chrome profile is removed after browser shutdown;
it never uses a signed-in user profile. Screenshots remain available for visual
review and can be removed afterward. It is separate from the
[local application baseline](../../tools/Test-LocalBaseline.ps1).

Prototype checks establish design navigation, copy, layout and interaction only.
The actual-component host establishes production UI behavior within its local
fixture boundary. Real SQL, API authorization contracts, actual authentication
and provider acceptance retain their distinct verification scopes.

## Keeping the design current

Update the journeys, glossary, screen copy, prototype and scenario mappings
together when implementation changes a design decision. Preserve stable UX
scenario IDs for traceability; they describe required outcomes, not a separate
completion checklist. Reconcile current behavior and proposed behavior at every
milestone closure.
