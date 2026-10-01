# Proposed screens and interaction design

This is the M2 screen contract for the retained Gateway. It describes layouts,
primary copy, representative offline interactions and required behavior. The M3
core source implements the onboarding, listing, handoff and lifecycle flow;
the M4 source implements the focused protection redesign. The prototype is not
production evidence or a second completion record. Actual verification belongs only in
[MILESTONES.md](../../MILESTONES.md).

Read this with [journeys and language](journeys-and-language.md) and the stable
[acceptance scenarios](acceptance-scenarios.md). The
[interactive prototype](prototype/index.html) contains only local HTML, CSS and
JavaScript. Serve its directory over static localhost; do not execute an
operational installer to view it. No dependency installation is needed.

## Prototype boundary and controls

The dark fixture toolbar is separate from the product shell. Its persistent label
is **“M2 / INTERACTIVE PROTOTYPE”** with **“Local simulation · synthetic data · no
authentication or provider calls.”** It offers Role, State, and Reset prototype.
The fixture has no token acquisition, provider transport, telemetry, remote asset,
cookie or browser-storage integration. Its content-security policy prohibits
network connections. Its example endpoint uses the reserved `.invalid` domain.

Role values are Administrator, Operator, Auditor, Support reader, and External
developer · guide only. The developer fixture is an integration document, not a
fifth Gateway UI role. Role changes remove any displayed one-time key. A fresh
page load or Reset discards all fixture changes. Synthetic key strings are never
real authentication material.

State values are Empty, Loading, Success, Error and Restricted. They describe
representative scenarios for the current screen, not live service state. Loading
stays selected until the reviewer changes it; no artificial timer claims a
provider result. Task-specific **Connection / Policy / Runtime state fixtures
(design only)** add pending, stopped, failed, unknown, read-error and expired
observations. A pending connection has a bounded local GET-readback model: the
reviewer supplies a synthetic terminal result and the next three-second check
observes it, then separately reloads its current-context snapshot. **Stop
automatic updates** and **Resume automatic updates** control only observation.
Elapsed time and Completed history alone never invent current provider readiness.
Error on registration, Registry setup, runtime testing and
installation uses the specific uncertain/stopped outcomes below. Other read
errors offer a safe refresh. Restricted overrides the view without exposing its
protected contents.

The prototype shows complete-list search, page navigation and aggregate counts
using a finite fixture of 143 records. The implemented listing contract is now
described in the [API guide](../api/api-contract.md); production UI tests use a
separate actual-component fixture. A prototype count is not API evidence and no
new aggregate endpoint is implied.

The production handoff supplies a PowerShell sample command using a compatible
configured HTTPS endpoint and exact external ID, with the key entered separately
by the sample. A configured local HTTP endpoint remains displayable, but the
HTTPS-only sample is not advertised as executable for it.
The design fixture's Bash example describes the same protocol. Production
registration also awaits a browser acknowledgment of the non-secret
`pendingExternalId` recovery URL before sending creation. Failed or disconnected
retention sends no create; refreshing an interrupted or discarded key handoff
does not resend it.
Automatic Registry completion additionally requires the current administrator,
server availability and a one-use circuit acknowledgment bound to the operation
and agent after key saving.

## Layout and interaction system

- Desktop: persistent left navigation; tenant/environment and role in the top
  bar; one main heading and short purpose statement; contextual primary action;
  a wide work card and narrower guidance card where useful.
- Navigation: Getting started, Overview, Agents, Settings. Provisioning operations
  open from an agent or its next task. There is no invented global operations or
  downstream-delivery dashboard.
- At 390 CSS pixels: navigation wraps into a compact row; work/guidance cards
  stack; form fields stack; table rows become labeled cards; actions wrap without
  losing labels. No control requires horizontal page scrolling.
- Information hierarchy: the outcome's **What happened**, **Why this matters**,
  **What remains**, and **Next step** come first; identity/scope follows.
  Protection logs start collapsed under **Technical operation details**, with
  descriptive step names and **“Skipped means not run, not passed.”**
  Other support references remain secondary. State always has a written label;
  color is supplemental.
- Keyboard: skip to main content; visible focus; native labeled inputs; headings
  receive focus after navigation; dialogs use native modality with explicit
  Tab/Shift+Tab wrapping, Escape cancellation, a named close button and return
  to the invoking control.
  Rendering a changed page must provide a new focus target if the invoker is gone.
- Copy: a button is named for its field; success displays “Copied” and announces
  “Copied to clipboard.” If clipboard access fails, the user can select text
  manually. Samples contain no key. User-provided display values are escaped.
- Confirmations: name the operation, selected identity and impact. Dismissing an
  unconfirmed dialog leaves that choice unapplied. It never claims to undo an
  already accepted tenant operation.

## Screen specifications

### Install Gateway — local installer, before the hosted portal

Prototype route: `#/installation`. Acceptance: UX-33, UX-29–31.

This is a compact fixture of the separate local Setup application, not a new
route on the deployed Admin UI. Entry is “View installation flow” from Getting
started for design review; the real first-install entry remains `gateway setup`.

| View | Exact primary copy and controls |
|---|---|
| Plan | **“Review your installation plan”**. “Check the tenant, subscription, capabilities, and cost choices before deployment.” Destination card names tenant, subscription, region and environment. Capability choices show shared Prompt Shields and optional Purview prerequisites. |
| Review | “I reviewed the destination, preview dependency, permissions, and cost choices.” **“Review and deploy”** opens **“Confirm this installation plan”**; final action **“Confirm reviewed plan.”** |
| Progress | **“Your Gateway is being prepared”**. “Keep this progress page open, or return to the preserved checkpoint later.” Completed resources, active verification and the eventual Admin UI handoff remain distinct. |
| Stopped | **“Deployment stopped at a safe checkpoint”**. “Completed steps are preserved. Review the failure before resuming.” **“Review resume”** describes remaining work; it does not replay the installation. Changed inputs require a new plan. |
| Verified | **“Your Gateway is installed”**. Verified Admin UI URL with copy; **“Open getting started.”** “An Active agent and policy behavior are separate next steps.” |

The prototype changes only screen state. Production acceptance separately checks
the exact source/configuration/target plan, real checkpoint recovery, Azure
resources, permission and cost boundaries, and verified HTTPS handoff.

### Getting started and Overview

Routes: `#/setup`, `#/dashboard`. Acceptance: UX-01, UX-13, UX-16–17, UX-28–31.

Getting started heading: **“From a ready Gateway to a connected agent.”** Four
ordered tasks are **“Choose the agent and its blueprint,” “Save the one-time
Gateway key,” “Complete Agent 365 setup,” “Connect and send an interaction.”**
Optional protection is a separate guidance card, not an incomplete mandatory step.

Overview heading: **“A clear view of your agents.”** The next-task card names its
specific agent and opens that same operation. Counters are **“Registered agents,”
“Active registrations,” “Action required.”** Counts must share one authoritative
scope and update with lifecycle changes. If the production API cannot provide a
complete aggregate, use a qualified count of returned records; never treat a
loaded page as the fleet total.

Empty: **“Your Gateway is ready for its first agent.”** Administrator action:
**“Register agent.”** Other roles see **“Administrator task”** rather than an
enabled registration control. An Active registration is not evidence that
telemetry arrived or that all protection services enforce.

### Register an agent

Route: `#/agents/register`. Administrator only. Acceptance: UX-02–04, UX-16,
UX-20–24, UX-28–31.

Heading: **“Register an agent.”** Description: **“Choose its identity, then
decide which optional protections it should use.”**

The work card contains three sections:

1. **“Give your agent a name.”** Agent name, generated stable external agent ID,
   signed-in owner and environment summary. Production permits the reviewed owner
   and environment selection from the existing contract. The fixture fixes owner
   and environment to clearly synthetic values.
2. **“Choose a reusable blueprint.”** Radios **“Use an existing blueprint”** and
   **“Create a reusable blueprint.”** Existing is the default. The selected typed
   blueprint is rechecked before provisioning. New asks for its reusable name.
   Each registration still gets its own child identity and key.
3. **“Choose what this agent uses.”** Independent Prompt Shields and Microsoft
   Purview switches; independent Agent 365 telemetry and Azure Monitor mirror.
   Both protections off is a valid completed choice. Purview on requires a
   reviewed shared/deferred policy authorization.

Primary action: **“Review registration.”** Review names the agent, external ID,
blueprint, and protection choices. Final action: **“Register and show key.”**
Repeated submission must not create another operation. The fixture performs one
in-memory transition; real idempotency/concurrency verification belongs to M3.

Empty blueprint inventory: **“No reusable blueprints yet”** with **“Create a
reusable blueprint.”** This is different from a failed inventory request. Unknown
registration result: **“Registration result needs checking”** and **“Check before
submitting again.”** **“Check agents”** leads to reconciliation by stable external
ID; an uncertain create is never given a blind resubmit action.

### One-time connection handoff

Route: `#/handoff`. Administrator only; reached immediately after accepted
registration or replacement issuance. Acceptance: UX-05–06, UX-30–32.

Heading: **“Save your connection details.”** Description: **“Your agent record is
created. Save the key now, then follow Agent 365 setup.”**

The warning **“This key is shown once”** precedes three copyable fields: Gateway
API endpoint (root HTTPS URL), external agent ID, and one-time Gateway key.
The sample command invokes the retained
[ExternalAgent.Sample](../../src/ExternalAgent.Sample/Program.cs), which accepts
the key through its non-echoing prompt rather than command arguments. The sample
uses a fixed-response model stub; the developer retains the evaluation gate when
replacing that callback with their model.

The checkbox **“I have saved the key in a secret manager”** enables **“Continue to
agent setup.”** Navigation away before acknowledgment opens **“Leave without
saving the key?”** with **“Stay and save key”** and **“Leave and hide key.”**
Revisiting shows **“This key is no longer available”** with **“Open agent details.”**
A key is issued before provisioning is complete; this screen never waits for
Registry completion before giving the developer the key.

### Provisioning operation and Registry handoff

Route: `#/operations/current` represents `/operations/{operationId}`.
Administrator and Operator may read; only Administrator completes Registry.
Acceptance: UX-07–09, UX-28–31.

The title names the selected agent. Seven steps preserve the existing workflow:
blueprint, principal, federation, child identity, observability authority,
administrator Registry completion, final verification. Progress is completed
steps, not elapsed time or an estimate of provider completion.

- Waiting: **“Administrator action required.”** Administrator gets **“Complete
  Agent 365 registration.”** Operator sees **“Ask a Gateway Administrator to
  complete this step. You can keep viewing progress.”**
- Unknown: **“The Registry result is not confirmed.”** **“Check existing
  registration”** is a readback action. Copy explicitly says **“A second create
  request will not be sent.”**
- Complete: **“Agent setup is complete.”** Registration is Active only after final
  identity verification. The guide link is **“Open integration guide.”**
- Reopen: **“Refresh status”** checks the same operation and never replays completed
  identity steps. A technical operation reference is available in the side card.
- Authentication recovery: **“Complete the Microsoft Entra sign-in, consent, or
  MFA prompt. Then return to this same operation.”** No Graph token paste field.

The fixture renders final success synchronously after its local confirmation;
actual provider waiting, consent, final verification and reconciliation need
their real asynchronous acceptance tests.

### Agents and agent details

Routes: `#/agents`, `#/agents/detail` representing `/agents/{agentId}`.
Acceptance: UX-06, UX-12–17, UX-28–31, UX-34.

Agents offers **“Search agents”** by name/external ID, status filter, **“Search”**
and **“Clear.”** Result text is **“1–10 of 143 agents”**; footer **“Page 1 of 15”**
with **“Previous”** and **“Next.”** Every page preserves the filters. Empty filtered
result: **“No matching agents”** and **“Clear filters.”** Empty registry:
**“No agents registered yet.”**

Details groups Registration, Protection choices, Developer handoff, and permitted
credential/lifecycle actions. Operation/history access follows the exact role
matrix in the journey guide. Administrators and Operators enable an eligible
Disabled registration or disable an Active registration; other states do not
present those transitions.

After **Continue to agents**, the user chooses an agent using the reviewed
blueprint and selects **Choose protection for this agent**. The review names
that agent, its profile/blueprint and independent Prompt Shields/Purview choices.
Only **Save this agent’s choices** applies the explicit choice; visiting details,
verifying a connection, saving policy or completing a test does not enable it.
Missing prerequisites explain why On is unavailable without rewriting the user's
choice to Off. Off remains a valid explicit choice. This per-agent action never
edits sibling choices or the shared policy.

Credential task: **“Issue replacement key.”** Explain **“Store the new key, update
the external agent, and then revoke the old key.”** Revoking the sole usable key
is blocked with **“Keep one usable Gateway key.”** With a replacement, **“Revoke
the old Gateway key?”** requires acknowledgment that the external agent has been
updated; successful old-key revocation leaves the replacement usable.

Deletion is explicitly **“Delete Gateway registration.”** Copy: **“This removes
the registration and its Gateway access. Microsoft Entra identities, Agent 365
registrations, and shared Purview policies remain.”** It never says “delete agent
everywhere.” Audit history is Administrator/Auditor only; provisioning history is
Administrator/Operator only. The static audit dialog is a small synthetic example,
not a proposed audit collection endpoint.

### Settings and optional protection tasks

Production routes: `/settings`, `/settings/connection`, `/settings/policy`,
`/settings/runtime`, `/settings/collection`, `/settings/defaults`. The compact
prototype uses corresponding hash routes. Acceptance: UX-16–19, UX-28–31, UX-34.

Settings uses focused tasks. **“Purview setup: follow these steps”** contains an
ordered **Connect tenant / Set shared policy / Test behavior / Review agent
choices** navigation. Its highlight means location, not passed work or active
protection. Explain that returning to an allowed step does not undo saved work.
Administrator-only behavior testing has an explanatory restricted step for other
governance readers. **“Other protection tasks”** contains Protection overview,
Optional data collection and, for Administrators, Registration defaults.
These are separate tools, not extra sequential steps. Prompt Shields usage is
selected per agent. Capability facts are visible to all four UI roles;
connection and policy details require Administrator/Operator. Inventory, changes,
confirmation and runtime results require Administrator.

A completed operation retained from a different task is collapsed under
**“Completed earlier task: [task name]”**. Explain that this is saved history,
not completion of the current step or proof of current protection. Keep pending,
failed and unreadable operation feedback visible. Never discard its recovery ID
or replay it while navigating to the next step.

Not installed is a neutral state: **“The optional capability is not installed in
this Gateway. Agents with Purview off can continue normally.”** It is not an error
or a broken core registration. A saved Enforce choice appears **“Configured”**
until current applicable evidence supports **“Enforcing.”** Simulation and Off
remain visibly distinct. Registration defaults affect future registrations only.
The shared projection also names **“Verification expired”**, **“Waiting for
blueprint”**, and **“Registration not active.”** Missing information stays unknown,
not Off. The readiness snapshot's `validUntilUtc` is an upper bound, not authority:
earlier context changes are rechecked by the server. Profile state is not the
status of the operation that configured it.

### Purview connection and inventory

Production route: `/settings/connection`. Administrators act; Operators may read
safe connection status without companion/inventory mutation controls. The
prototype demonstrates both views without establishing real authorization.
Acceptance: UX-18–19.

Acceptance additionally includes the complete onward journey in UX-34.
Waiting heading: **“Connect the tenant and load its inventory.”** The production sections
explain shared prerequisites, tenant connection and the existing classifier
inventory. Show the actual returned SIT count and define a sensitive information
type in plain language. Do not show a dropdown or imply that a policy classifier
must be chosen here. Invalid or mismatched inventory cannot produce a trusted
count; an expired inventory remains visibly expired. Loading saved inventory
does not renew it. Classifier selection belongs only in the policy step; the
optional collection task retains its meaningful separate selector.
The connection explanation distinguishes administrator
sign-in and classifier definitions from the Gateway's independent app-access
check. The helper neither reads prompts/documents nor creates a policy, enables
protection or transfers the administrator session. Only matching, independently
checked evidence produces **“Purview connection verified.”** Inventory is **“Current”** or
**“Refresh required,”** never inferred from the presence of an old download.

The completed connection leads with this panel, not a Completed/Skipped timeline:

| Label | Required meaning and primary copy |
|---|---|
| **What happened** | The Gateway independently verified its own configured app access and loaded a current classifier inventory. |
| **Why this matters** | The Gateway needs its own access and exact classifier definitions before a shared policy can be reviewed; administrator sign-in alone does not grant it. |
| **What remains** | No shared DLP policy was created, no agent was enabled, and DLP blocking was not tested. Optional collection and downstream telemetry delivery are separate. |
| **Next step** | Choose a blueprint shared by agents and review its exact classifiers, thresholds, mode and shared impact. Primary action **Continue to shared policies**. |

That primary action waits for a click or keyboard activation. Completion never
automatically navigates or configures anything. Below the panel, connection
context names tenant, expected administrator, original operation, inventory
generation and explicit UTC times. The collapsed **Technical operation details**
preserves the historical result. Descriptive step labels explain independent
app-access/inventory verification and why policy authoring or behavior tests were
Skipped, meaning unrun, not passed.

Recovery copy and actions:

| Condition | Exact copy and next action |
|---|---|
| Wrong tenant/account | **“This connection belongs to another tenant.”** or **“This connection belongs to another administrator.”** Refresh the signed-in tenant or use the administrator recorded on the existing operation. |
| Unconfirmed cancellation | **“Review cancelled.”** No mutation was sent from that review; previously accepted work is unchanged. |
| Browser recovery acknowledgment failed before submission | **“The protection action was not completed”** with **“The browser could not confirm that it saved this operation's recovery link. No confirmation or protection change was sent for this action. Reload this page, check its current status, and review the action again.”** Do not expose exception text or misclassify this as provider failure or an uncertain submitted result. |
| Accepted work left open | **“This connection is waiting for completion.”** **“Check existing operation.”** Recover the same actor-bound launch; closing the companion does not roll back accepted work. |
| Expired inventory | **“Refresh the classifier inventory.”** “Your earlier choices remain visible, but they need review against the current inventory.” |
| Known expired companion launch | **“Connection launch expired.”** The matching administrator uses **“Review connection refresh”** for a new review, confirmation, operation and launch. The expired command remains unusable; pending verification and unknown or mismatched work remain blocked. |
| Completion accepted | **“Companion result received. Checking Gateway access.”** Keep the original operation and refresh its progress; do not submit the result again. **“DLP protection is not enabled by this step.”** |
| Pending verification | Heading **“Checking the Purview connection”**. Automatically observe the original operation by GET every three seconds for at most five minutes; never submit another result. **“Stop automatic updates”** pauses only observation. Terminal readback reloads current connection/inventory context, not just the old timeline; current expiry still prevents a ready claim. |
| Observation stopped by the user | **“You stopped automatic updates.”** Accepted work is unchanged. **“Resume automatic updates”** reads the same operation within a fresh bounded session. A manual **“Check connection status”** does not restart automatic updates. |
| Observation budget exhausted | **“Automatic updates stopped after 5 minutes.”** The original operation may still be running. **“Resume automatic updates”** starts another bounded read-only observation session for that operation, not another connection. |
| Completed readiness expired | Heading **“Connection verified earlier; refresh required”**. Preserve historical Completed, remove current-ready claims, and offer **“Review connection refresh”** for a fresh authorization. Never replay the old result or renew its deadline. |
| Independent verification failed | **“Connection verification failed.”** A successful Windows sign-in alone does not verify the Gateway's access. Show **“Failure reference”** and the correlation ID; resolve the cause before another reviewed attempt. Failed remains Failed after the old expiry. |
| Unknown result / failed status read | **“The connection result is not confirmed”** / **“Connection status could not be checked”**. **“Check connection status”** reads the original operation. No create retry, fresh authorization or companion resubmission is offered to recover this uncertainty. |
| Missing prerequisite / wrong role | Name the unavailable capability or required administrator, preserve saved choices, and offer the permitted Settings/agent path. Operators read safe status without Windows, policy-mutation or runtime-test controls. |

The production review shows tenant, administrator, operation, generation and
expiry, with times explicitly labeled UTC. The first-run instructions are:

1. **"Download, then open its folder."** Use the browser's Show in folder action;
   do not double-click the script.
2. **"Open PowerShell 7 in that folder."** In File Explorer, right-click empty
   space and choose Open in Terminal; use `pwsh -NoLogo -NoProfile` if needed.
   If PowerShell 7 is missing, use the organization's approved installation
   process. Check the folder and filename if needed.
3. **"Trust this one download before running it."** Review the file and respect
   organizational policy. **"Trust this downloaded file"** shows the copyable
   `Unblock-File -LiteralPath '.\Connect-PurviewTenant.ps1' -ErrorAction Stop`.
   **"Copy trust command"** reports **"Trust command copied."**, or **"Copy was
   unavailable. Select the trust command and copy it manually."** No output is
   normal; only the file's download marker changes, not execution policy.
   A blocked script cannot unblock itself. Enforced signing still requires an
   approved signed copy; never lower or bypass policy.
4. **"Run the full connection command."** Copy **"Run the connection"** before
   its displayed UTC expiry. Do not edit its IDs or expiry.
5. **"Sign in and wait for the result."** The expected administrator completes
   official Microsoft sign-in and waits for `A365GW_CONNECTION_RESULT:`.
6. **"Copy that result and paste it below. No file is needed."** Copy the entire
   result line, including its prefix, without commands or sign-in messages.

The labeled, multiline **"Paste companion result"** field is primary. Help says
**"No text file is required."** The collapsed **"Or upload a saved result
(optional)"** section retains **"Upload companion result file"** for an already
saved result. Both paths enforce the same bounded validation; changing input
clears the earlier evidence and completion approval. Copying surrounding
whitespace is allowed; multiple lines of output, repair results and raw JSON are
not. A realistic result above 32 KiB must not disconnect the interactive circuit.

Never change an expired command's deadline. The page awaits retention of the
original source operation ID before confirming its separate completion approval.
**Go to companion result** changes only the scroll target. The subsequent
paste/review/submit sequence must succeed without a reload, while retaining the
same operation and all approval checks. A current browser fragment is preserved,
not compared as though it were a different tenant, operation or profile.
Reopen reads the accepted launch without renewing its expiry. Pasting or uploading
matching output requests independent verification; it does not itself report
Connected. Acceptance, reload and lost-response recovery keep the original
connection ID; a guarded GET can follow an old Submitted approval's reference.
Pending/unknown completion hides the helper. The design fixture separately
simulates first-run instructions, a synthetic-only paste, result submission and
the later verification outcome; it never reads real files, downloads a companion
or authenticates. Local
component/browser fixtures establish client behavior; real Windows/Microsoft
authorization remains M6.
Reopening the connection task without an operation reference can review an
authoritatively expired waiting connection. A retained operation additionally
requires the exact actor, target and launch binding before offering that review.

### Shared policy review

Routes: `/settings/policy` and `/settings/policy?profile={id}`; matching prototype
hash routes. Acceptance: UX-20–24, UX-28–31, UX-34.

Without a selected profile, use **“Choose a shared blueprint policy”** and an
explicit blueprint/profile selector. The prototype deliberately lists another
profile before Contoso assistants; no first record is selected implicitly.
An invalid requested ID says **“Shared policy not found”**, with
**“Choose another shared policy”** or **“Back to agents.”** It does not load an
unrelated editor or lose the requested context.

The editor is **“Review the shared policy.”** The impact information identifies the
blueprint and affected agents. The fixture has a complete synthetic membership
list; production may show an exact count only when authoritative. Otherwise say
**“This policy affects every agent using this blueprint.”** Never infer scope from
the first page or the first 100 loaded registrations.

In production, place the active editor before **“Saved policies and verification
details (N)”**, a secondary disclosure. Start with **“Which blueprint uses this
shared policy?”** and explain that a blueprint is shared identity, not an
individual agent. Do not repeat a locked blueprint selector inside that editor.
The saved library opens for an explicitly selected profile, runtime task or a
matching failed operation. **Review settings** moves focus to the editor heading
instead of leaving the user at a card that appears unchanged.

Controls: **“Mode”** with Enforce, Simulation with tips, Simulation without tips,
and Off; multiple classifier selections; independent minimum/maximum count and
confidence for every selected classifier. Tips are provider/client dependent and
are not promised merely because the mode is selected. A new policy has no default
classifier. The existing-policy fixture starts with its saved classifier.
Separate the searchable selection list from threshold fields for selected types.
Each newly added type starts with **1 / Any (-1) / 75 / 100**, in minimum-count,
maximum-count, minimum-confidence, maximum-confidence order. Explain count,
Any, confidence and OR matching. The values are editable starting points, not a
claim of classification quality. Preserve saved thresholds and an edited
deselected/reselected draft; unknown legacy thresholds require explicit review
and never receive invented values.

**“Review protection choices”** shows mode, every selected classifier and all thresholds,
affected scope, and **“I understand this policy is shared by every agent using
this blueprint.”** Final action: **“Confirm and queue shared policy.”** Cancelling discards
unconfirmed edits and preserves the saved mode. A changed configuration invalidates
earlier behavior proof; saved configuration alone does not claim enforcement.

Accepted configuration stays on the exact profile with an explained pending
outcome and **Check existing operation**. A current saved Enforce outcome has the
heading **“Policy saved; behavior is not verified”** and primary **“Continue to
behavior tests”**, linking to `/settings/runtime?profile={same-id}`.
The four-label panel explains configuration versus behavior, shared effect,
required approved tests, and the next task before technical details.
The current profile and its saved mode are distinct from the operation's status.

Saved Off says **“Policy saved; Purview is off”**, with **Continue to agents**:
no runtime test is required. **“Policy saved in simulation”** also leads to
**Continue to agents**, with secondary **Optional behavior diagnostics** for the
same profile. Simulation is non-blocking; tips depend on provider/client support.
Collection is optional and separate, never a DLP prerequisite. Expired connection
or inventory prerequisites explain the required reviewed refresh; they do not
erase a saved Off choice or manufacture a current enforcing badge.

Concurrency requires **“Reload and review changes.”** An expired or changed draft
requires a new explicit review. **“The shared policy result is not confirmed”**
offers **“Check existing operation.”** Do not silently apply the stale
choice, refresh a confirmation token, or replay an uncertain policy mutation.

When a policy read expires or times out, explain the specific bounded failure,
that previous steps may have taken effect, and that missing readback does not
prove Microsoft objects absent. If prerequisites are stale, first lead to the
connection. Preserve an unsaved editor in a clearly labelled separate tab while
that connection is refreshed, then explicitly reload prerequisites in the editor.
GET alone never renews a connection or old review.

For the exact saved profile, **“Review existing policy check”** means read-only
Microsoft reconciliation, not another create. Explain every disabled condition.
After a genuinely refreshed connection, a new review and confirmation may bind
the same exact saved selections to its current inventory and invalidate earlier
runtime proof. Profile/provider identities, settings, shared scope and agent
choices stay unchanged. Missing/renamed selections, incomplete thresholds,
expiry or concurrent change reject safely. An old operation/review is never
silently rebound. A link with another profile's operation must first open that
operation's exact profile; a runtime-page recovery links back to the policy task.

### Honest activity feedback

Use a small indeterminate indicator and stable explanatory text for actual page
requests and active bounded status observation. Show the last successful check
and available saved step/elapsed context. Do not invent percentages, an ETA or
Microsoft-side activity. Pending work, observation paused, a failed read and
expired readiness are different states. Stopping automatic updates does not
cancel accepted work. Reduced-motion mode retains a static visible/text cue;
clock changes must not repeatedly interrupt a screen reader. Apply this to
connection, shared policy, reviews, inventory reads and runtime continuation,
with keyboard, narrow-width and 200%-zoom acceptance.

### Approved runtime samples and results

Routes: `/settings/runtime` and `/settings/runtime?profile={id}`; matching
prototype hash routes. Administrator only. Acceptance: UX-25–27, UX-28–31, UX-34.

Heading: **“Test policy behavior.”** Description: **“Approve a bounded set of
synthetic samples before testing the selected shared policy.”** Start with the
four-label outcome/next-step panel and exact current profile context, not a
historical receipt. Without an exact profile, require selection; an invalid ID
never silently falls back to another profile.

Guide the administrator to approve a **Clean negative control** and an
**Intended example** for every selected sensitive information type. The fixture
contains two fixed fictional examples (employee identifier and project code)
and a clean control. It displays the selected examples for explicit approval;
it does not read private files, accept real sample text, compute a classifier
match or call a provider. Review includes sample
identities, exact profile/revision, policy mode, thresholds, execution identity,
intended classifiers and effective scope. The final action
is **“Confirm and send approved batch.”** Production admission additionally validates exact
sample hashes, complete per-classifier coverage, byte/count limits, inventory,
actor, profile row version, scope and single-use confirmation.

For matching current Enforce evidence, the main heading is
**“Approved behavior is currently verified”**, and the outcome's primary action is
**“Continue to agents.”** Explain that each request still needs evaluation and
that the next step is choosing protection for an agent explicitly, not automatic
enablement. Saved-profile revision, effective scope, connection, inventory and
expiry all remain relevant; an old receipt alone never certifies current use.
**“Historical runtime test receipt”** is a secondary report heading.
Scope copy: **“This result does not
identify which individual sensitive information type matched. It does not certify
untested content.”** Enforce expects both allowed and blocked behavior; simulation
is non-enforcing. **“Simulation diagnostics complete”** is not a block proof, and
the optional diagnostic path also returns through **Continue to agents**.
Off shows **“This policy is off”**, explains **“No runtime test is required,”**
and permits no new runtime test. Earlier reports remain historical, not present
enforcement evidence. Collection is not required in any of these paths.

Unknown result: **“The test result is not confirmed.”** **“Check test status.”**
If still unresolved: **“This result needs administrator review.”** No automatic
sample replay. Expired proof: **“Historical result; current verification required”** with
**“Review connection readiness”** or **“Review new samples”**, according to the
actual blocker. Refresh the affected connection or classifier inventory and repeat
the policy review when required before approving a new test. A new test needs a
separately approved sample set; samples are not silently retained for later execution.
The actual UI starts with **“Verify shared profile”**, then **“Review test batch”**
and a separate approval of the returned execution identity. Raw text stays in the
private browser module and crosses only the explicit HTTPS portal request. Safe
recovery is `/protection/runtime-tests/{operationId}` and never resends text.
The backend execution deadline is 60 seconds; longer browser/interop budgets
include confirmation, lock and cleanup time rather than extending provider work.

### External developer handoff

Route: `#/integration`. Acceptance: UX-10–11, UX-32.

Heading: **“Connect your external agent.”** Ordered actions are readiness check,
always evaluate the prompt, validate an allowed/unexpired receipt, model callback
once, and submit the same interaction with its receipt. The external agent hosts
and calls its own model. The example command contains no key and uses the sample’s
non-echoing credential prompt.

A denial or receipt already known to be invalid/expired prevents generation.
The client cannot know every later policy change: the server rechecks context
when ingesting the interaction. A mid-generation invalidation can reject ingest;
the sample never automatically obtains replacement proof or regenerates. Gateway
acceptance, export attempt, and confirmed downstream delivery remain distinct.

## State layout shared by every route

| Fixture | Layout and primary copy |
|---|---|
| Loading | Heading remains; work card has `aria-busy`, loading text and neutral skeleton lines. No saved/current success values are fabricated. |
| Read error | Alert **“We couldn’t load [task]”**; **“Your saved settings have not changed. Check again to load the latest information.”** **“Try again”**, contextual return, and support reference disclosure. |
| Empty | Screen-specific next action described above. For read-only views, state what an administrator can do without showing an unauthorized action. |
| Restricted | **“This task needs another role.”** Explain required role and current role. **“Back to agents.”** No hidden protected data is fetched or rendered. |
| Success | Current fixture data and only permitted actions; a success badge names the exact fact demonstrated. |

## Review and implementation boundaries

The prototype is a review artifact for representative state, navigation, language,
focus, modal, copy and narrow-layout behavior. Its three-second/five-minute
observation model, profile-context checks and expired-result fixtures operate
only on synthetic in-memory state. They do not establish server-side concurrency,
multi-user ownership, provider permissions, authoritative receipt validation,
actual SQL, real clipboard permissions, authentication, automated Registry
completion, real readiness or Windows companion execution. It uses a
single new-registration fixture, two separate shared-profile fixtures and
per-agent in-memory credential metadata rather than production persistence.

Browser outcomes and any known remaining issue belong on the relevant milestone
item after actual execution. The acceptance document specifies the remaining M3/M4
tests; no synthetic success, screen text, static review, or old test count closes
those implementation or hosted acceptance tasks.

Current implementation references:
[registration](../../src/Gateway.AdminUi/Components/Pages/RegisterAgent.razor),
[operation progress](../../src/Gateway.AdminUi/Components/Pages/OperationStatus.razor),
[agent list](../../src/Gateway.AdminUi/Components/Pages/Agents.razor),
[agent details](../../src/Gateway.AdminUi/Components/Pages/AgentDetails.razor),
[Settings](../../src/Gateway.AdminUi/Components/Pages/Settings.razor),
[role policies](../../src/Gateway.AdminUi/Authentication/GatewayPolicies.cs), and
[runtime-test contract](../../src/Gateway.Api/Controllers/PurviewRuntimeTestsController.cs).
