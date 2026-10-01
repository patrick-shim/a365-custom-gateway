# User journeys and shared language

This is the **M2 journey and language contract**, used by the M3 core and
M4 protection implementations. It specifies navigation, role boundaries and
wording; a design statement alone does not establish implementation or hosted
behavior. Current behavior is identified explicitly below. Completion belongs only in
[MILESTONES.md](../../MILESTONES.md). The
[product brief](../spec/product-brief.md) and [API contract](../api/api-contract.md)
remain the references for product scope and server behavior.

This guide defines shared state labels, their meaning and the information each
journey must convey. The [screen design](screen-design.md) supplies canonical
screen-specific headings, controls and messages; supporting journey copy below
illustrates the same meaning where a screen needs more detail.

## Product promise and boundaries

Help an administrator connect an independently hosted agent to Agent 365, give its
developer the Gateway connection details, and operate that registration with clear
optional protection choices. The external agent continues to host and call its
own model. The Gateway owns registration, the per-registration key, prompt
evaluation and ingestion; the UI must explain each handoff.

Keep four kinds of information separate on every screen:

| Information | Example | Meaning |
|---|---|---|
| Registration | Active | The Gateway registration completed provisioning and is enabled. |
| Installed capability | Purview: Installed | The deployment has verified prerequisite capability facts. |
| Saved choice | Purview: Simulation | The saved policy mode is non-enforcing. |
| Current behavior/evidence | Purview: Enforcing; checked at a stated time | Current applicable evidence supports enforcing use; each request is still evaluated. |

An API health response does not verify every Microsoft dependency. An Active
registration does not prove exported telemetry arrived. A saved Enforce choice or
a completed configuration operation does not establish current enforcement.

## Navigation contract

Retain the existing route families. Core onboarding, listing, handoff and operation
navigation are implemented in the M3 source. Focused Settings/protection sections
are implemented in the M4 source using existing server endpoints.

| Navigation or entry | Existing page/route | Proposed purpose |
|---|---|---|
| Getting started | `/setup`, alias `/getting-started` | One next step: register, save the key, finish registration, then connect the external agent. |
| Overview | `/dashboard`, alias `/` | Current Gateway health and authoritative listing totals, with clearly limited previews. |
| Agents | `/agents` | Find a registration; open its current state and permitted actions. |
| Register agent | `/agents/register` | Administrator task reached from Getting started or Agents. |
| Agent details | `/agents/{agentId}` | Summary, Connect your agent, Protection, Operations, and Audit sections, according to role. |
| Settings | `/settings` | Focused sections: Capabilities, Purview connection, Shared policies, Know Your Data, and Defaults; show only permitted detail/actions. |
| Registration progress | `/operations/{operationId}` | Contextual operation page for administrators and operators. |
| Protection test report | `/protection/runtime-tests/{operationId}` | Administrator's historical test result alongside current profile readiness. |

Shared-policy and runtime continuation retains the exact profile through
`/settings/policy?profile={id}` and `/settings/runtime?profile={id}`. Without a
profile context, ask the administrator to choose the shared blueprint; do not
silently select the first returned profile. An unavailable requested profile
explains the limitation and offers the permitted profile list or Back to agents.
An onward link never grants authority or confirms a configuration.

Do not add a global operations, audit, traffic or telemetry dashboard that implies
an API collection or delivery metric exists. Operation links remain attached to
their registration or known protection operation. Preserve the distinction
between registration operations and protection operations.

Use **Getting started** for the deployed portal. Use **Install Gateway** for the
temporary local Setup application: its `/setup/...` routes are on a separate local
origin and are not the deployed portal's setup page.

## Role and access contract

The following is **current API authorization**, preserved by the proposed design.
Role names below omit the `Gateway.` prefix. A person with multiple roles receives
the union of those permissions. Tenant/user validation and operation ownership
checks still apply; a visible navigation item never grants API authority.

| Resource or action | Administrator | Operator | Auditor | SupportReader |
|---|---|---|---|---|
| Agents, agent details, protection capabilities | Read | Read | Read | Read |
| Create registration; blueprint inventory | Allowed | — | — | — |
| Enable or disable a registration | Allowed | Allowed | — | — |
| Registration operation and provisioning history | Read | Read | — | — |
| Complete Agent 365 registration with delegated user access | Allowed | — | — | — |
| Retry eligible provisioning; delete registration | Allowed | — | — | — |
| Credential metadata, issue and revoke | Allowed | — | — | — |
| Edit agent features | Allowed | — | — | — |
| Agent audit events | Read | — | Read | — |
| System configuration/defaults | Read/write | — | — | — |
| Purview connection, Know Your Data and shared DLP profiles | Read/write through reviewed operations | Read | — | — |
| Sensitive-information-type inventory | Read | — | — | — |
| Protection reviews, confirmation and mutation | Allowed | — | — | — |
| Known protection administration operation | Read | Read | Read | Read |
| Approved runtime-test review, execution and report | Allowed, subject to actor ownership | — | — | — |

Current page policy permits all four roles to enter Settings, but only the permitted
sections may fetch their data. A SupportReader or Auditor sees capability facts,
not a failed attempt to fetch administrator configuration. An Operator can view
saved policy state without seeing an editable form or synthetic sample input.
Protection operation API read access does not grant access to the administrator-only
runtime report page or authorize a new global operations screen.

Hide actions a role can never perform. Disable an otherwise authorized action only
for a meaningful current state, explaining why beside it. Direct restricted links
show **“This task needs another role”**, name the required administrator,
administrator/operator or administrator/auditor access as appropriate, explain the
current role, and offer **“Back to agents”**.
Role restriction is neither a failed service nor an empty data set.

The **external developer** is an integration persona, not an additional portal
role. Their runtime uses its registration's Gateway key. If that person also uses
the portal, their assigned Gateway roles determine its access.

## Journeys

### Installation operator: local setup to verified portal handoff

This operator is the person performing installation with the required Azure/Entra
authority, not necessarily a user assigned `Gateway.Operator` in the deployed app.

| Stage | Entry and decision | Proposed outcome and wording | Recovery |
|---|---|---|---|
| Start | Launch the canonical `gateway setup` flow; use its temporary local session. | **“Install Gateway”** / **“Choose where to install the Gateway, review the plan, then follow deployment.”** | Explain a missing local prerequisite by name; return to that step after it is available. |
| Select target | Read current authenticated account, tenant and subscription; select the exact target, region and project identity. | **“Review your Azure target”**; show subscription name and ID together, plus tenant ID. | Wrong account/tenant: return to account selection; do not infer authority from an old checkpoint. |
| Configure | Select supported development profile and optional capability preparation; retain required preview/cost/authority acknowledgments. | **“Capabilities to install”** / **“Agent-level protection is configured after installation.”** | Unsupported or changed choices invalidate the plan; return to the affected fields. |
| Review plan | Create a plan for the exact current source, target and configuration. Review resource changes and permissions before the allowed deployment action. | **“Review deployment plan”**, **“Deploy reviewed plan”**. | **“The configuration changed. Create a new plan before deploying.”** An old fingerprint does not authorize a changed target. |
| Follow work | Show the actual current stage, last update and whether work continues or requires action. | **“Deployment in progress”**, then **“Verifying deployment”** when readbacks run. | Cancellation/interruption: inspect recorded state; offer resume only after the existing eligibility/review contract allows it. Unknown provider outcomes require exact readback, not repeat creation. |
| Handoff | Verification supplies the exact Admin UI and API endpoints. | **“Gateway deployment verified”** / **“Open Getting started”**. Explain that the next task is registering an external agent. | Without verified endpoints, stay on progress with **“Deployment verification is incomplete”**; never invent or enable an unverified portal URL. |

The setup experience must preserve the source-bound plan, deployment ownership,
accepted target and resume rules. It must not suggest that a deliberately deleted
environment can be resumed from old local artifacts. Hosted installation remains
a separate later acceptance scope from this M2 design.

### Administrator: first registration and connection handoff

**Entry:** Getting started after tenant sign-in, or **Register agent** from Agents.
For an empty installation, lead with **“Connect your first agent”** and explain
**“Register the agent, save its Gateway key, then finish Agent 365 registration.”**
Protection is optional; intentionally unused protection is not an incomplete
onboarding task.

1. **Identify the agent.** Ask for a name, description and supported environment;
   show the signed-in owner. Explain **“External agent ID”** as **“Send this ID with
   this registration's Gateway requests.”** Keep the generated identifier stable
   through validation and uncertain responses.
2. **Choose a blueprint.** Offer **“Use an existing blueprint”** and **“Create a
   blueprint”** with **“A blueprint can be shared. This registration receives its
   own child Agent ID and Gateway key.”** Select only the current compatible
   inventory; a failed inventory read is not an empty inventory.
3. **Review features.** Show actual system-derived telemetry defaults and independent
   Prompt Shields/Purview choices. Offer **“Configure protection later”** as a
   deliberate choice. Do not silently change a configured default or interpret a
   loading response as Off. A selected new policy still requires its explicit review.
4. **Submit once.** **“Register agent”** becomes **“Registering…”** and prevents a
   second submission. Accepted means provisioning started, not Active.
5. **Save the key before navigation.** Lead with **“Save your Gateway key”** and
   **“This key is shown once. Store it in your agent's secret manager.”** Present
   Gateway API URL, external agent ID, key and expiry as distinct fields. Show copy
   success only after successful clipboard access; otherwise retain manual selection.
   Provide a sample command containing non-secret values only. **“Continue to
   registration progress”** leaves the one-time screen; it must never depend on
   secret persistence in browser storage, a URL, logs or documentation.
6. **Complete the delegated handoff.** At the actual waiting state show
   **“Administrator action required”**, **“Complete Agent 365 registration”**, and
   **“Use your signed-in administrator account to complete this step.”** Preserve
   Microsoft consent/MFA handling, server eligibility and the one-POST Registry
   recovery boundary. A permitted automatic development handoff is still delegated
   and must not run while the key handoff is incomplete.
7. **Connect the runtime.** When Active, use **“Registration active”** and
   **“Configure your external agent with the API URL, external agent ID and saved
   key.”** Lead to the existing sample/pre-model integration instructions. A key
   readiness probe verifies that authentication boundary; it does not prove a
   complete interaction or downstream delivery.

**Recovery:** Field validation keeps non-secret inputs and focuses the first error.
If registration acceptance is uncertain, show **“The registration may already
exist. Check Agents before trying again.”** A lost key requires a replacement from
the existing registration, then verification before revoking the old usable key.
An interrupted Registry action uses **“Check registration status”**, not another
create. If the server says retry is unsafe, show its next action instead of Retry.

### Administrator: optional protection and ongoing configuration

**Entry:** Agent details → Protection for the agent's choices; Settings → Purview
connection or Shared policies for shared prerequisites and policy work.

**Decisions:** Choose Prompt Shields independently. For Purview, distinguish tenant
connection, current classifier inventory, shared blueprint DLP profile, and
optional Know Your Data collection. Choose existing compatible policy or reviewed
configuration; do not offer both simultaneously. Select real classifiers and
explicit thresholds, then choose Enforce, simulation, or saved Off.

**Review and outcome:** Use **“Review shared policy”** with
**“This policy applies to every agent using this blueprint.”** Show the exact
blueprint, modes, classifiers, thresholds and actions. Require the existing shared
impact acknowledgment for changes to an existing profile and preserve separate
review, confirmation and execution. A new-blueprint intent says **“Waiting for
this agent's blueprint”** until that exact registration binds; it is not portable
consent for another agent. Report saved choice, operation progress and current
readiness separately.

For sample verification, **“Review test samples”** precedes **“Run approved samples”**.
The review identifies the actual server-selected test registration and shared
policy scope. **“Approved sample behavior verified”** describes the historical
result. The outcome heading **“Approved behavior is currently verified”** and
**“Purview enforcing”** additionally require current applicable evidence.
State **“These results do not identify which sensitive information type matched.”**
Simulation does not require enforcement certification. Disabled policies do not
offer runtime execution.

**Recovery:** Cancelled companion sign-in leaves connection unconfirmed. Wrong
tenant/administrator, expired inventory, stale row version or changed review
requires fresh discovery/review, preserving non-secret work where valid. Do not
replay old consent. For interrupted sample execution use **“Check test result”**;
do not re-submit raw content automatically. Expired readiness names the specific stale prerequisite and recheck action;
the historical report stays historical. For a formerly completed connection,
use **“Connection verified earlier; refresh required”** rather than relabeling
the original operation as Failed.

A known expired companion handoff says **“Connection launch expired.”** Its
permitted administrator uses **“Review connection refresh”** to obtain a new
review and confirmation, not to renew the old command. Preserve the previous
operation and reject its stale evidence. Unknown outcomes, active verification
and mismatched retained bindings still require readback rather than replacement.

The companion's successful sign-in and classifier read are not a verified Gateway
connection. It reads definitions, not prompts or documents, and transfers no
sign-in session. Submission continues the original connection under a separate
approval. Use **“Companion result received. Checking Gateway access.”** until the
Gateway independently verifies its configured app access. Preserve the original
operation ID through acceptance, reload and lost-response GET recovery; never
resubmit to fix a display error. An old Submitted approval link can follow only
its validated reference. Genuine failure says **“Connection verification failed.”**
with a bounded **“Failure reference”**, not another Windows sign-in instruction.
Connection verification does not enable DLP. Display connection/timeline times
explicitly as UTC, and never extend a command's expiry manually.

For a first-time Windows user, order the instructions as download, open
PowerShell 7 in that folder, review/trust the exact file, run the current full
command, sign in, and paste the complete result. Show **"Trust this downloaded
file"** with **"Copy trust command"** before **"Run the connection."** Explain
that no `Unblock-File` output is normal, that the command removes only the file's
download marker, and that a blocked script cannot execute a self-unblocking step.
Respect organizational signing/download restrictions; do not suggest lowering or
bypassing execution policy.

The primary field is **"Paste companion result"**. Say **"No text file is
required."** Keep **"Or upload a saved result (optional)"** as a secondary path.
Both paths accept only the same fresh `A365GW_CONNECTION_RESULT:` line, with
surrounding whitespace allowed. Explain invalid input without demanding another
sign-in just to recopy a valid console result. Editing or replacing it requires a
new completion review; neither input path alone asserts Connected or DLP enabled.
**Go to companion result** is a same-operation scroll shortcut, not a new task.
Follow it through paste, review and submission in the real browser without a
reload. If browser recovery cannot be acknowledged before dispatch, explain
**"No confirmation or protection change was sent for this action."** Follow with
the reload/status/review instructions, not a generic retry or provider-permission
diagnosis. Submitted-but-unknown work still requires readback of its original ID.

### Administrator: complete the novice protection journey

Acceptance: [UX-34](acceptance-scenarios.md#ux-34--complete-the-novice-protection-journey).
Every task presents a concise **What happened / Why this matters / What remains /
Next step** panel before the technical log. Keep **Technical operation details**
collapsed initially, with descriptive step names. Explain **“Skipped means not
run, not passed.”** Skipping policy authoring or runtime tests in a connection
operation is not proof those tasks succeeded.

1. **Understand connection completion.** **“Purview connection verified”** means
   the Gateway independently verified its own app access and loaded a current
   classifier inventory. The purpose is to prepare exact shared-policy review,
   not to transfer the administrator's sign-in. State explicitly that no policy
   was created, no agent was enabled, and DLP blocking was not tested.
   **“Continue to shared policies”** waits for the user's action.
2. **Choose shared scope and review its effect.** Choose the blueprint shared
   by the intended agents. The connection page summarizes how many existing
   sensitive information types were found; there is no selection there. A
   sensitive information type (SIT) is a classifier definition, not a new policy.
   Select types once in the shared-policy editor, then adjust their thresholds.
   Newly added types start at minimum count 1, maximum count Any (`-1`), minimum
   confidence 75 and maximum confidence 100. These are visible editable starting
   values, not proof that a type will match, and not a repair for unknown legacy
   values. Saved and deselected/reselected draft values remain unchanged.
   Review the exact profile, blueprint identity,
   classifiers/IDs, per-classifier thresholds, mode and shared impact. Preserve
   separate review, confirmation, accepted operation and saved-profile readback.
   Neither connection completion nor opening this screen configures a policy.
3. **Understand the saved choice.** Saved Enforce says **“Policy saved; behavior
   is not verified”**, with **“Continue to behavior tests”** for that exact
   profile. Saved Off is complete without a runtime test. Simulation stays
   non-blocking; diagnostic testing is optional, not an enforcement prerequisite.
   Know Your Data collection is optional and separate in all three paths.
4. **Approve private, bounded behavior tests when needed.** Guide the
   administrator through a clean negative control and examples intended for
   each selected sensitive information type. Explain the exact saved profile,
   mode, thresholds, execution identity and effective scope before approval.
   Samples are ephemeral and not retained for replay. A historical receipt
   alone is insufficient: current saved-profile, scope, inventory and expiry
   determine readiness. No individual matched-SIT attribution is invented.
5. **Make an explicit agent choice.** A currently verified profile leads through
   **“Continue to agents.”** The user chooses an agent using that blueprint,
   reviews its independent Prompt Shields/Purview choices, and explicitly saves
   them. No stage silently enables an agent. Any downstream telemetry delivery
   and optional collection configuration remain separate tasks.

Pending connection work says **“Checking the Purview connection.”** Observe only
the retained original operation by GET every three seconds, for at most five
minutes. **“Stop automatic updates”** pauses only observation, not accepted work.
Refresh current context after terminal readback; Completed history does not
override an expired current snapshot. If stopped by the user or budget, say
updates stopped, not that provider work failed, and offer **“Resume automatic
updates.”** Resuming observes the same operation within a fresh bounded session
without another submission. Manual status checks do not silently restart a
stopped observation session.
Leaving/reopening, failed reads and unknown outcomes do not create replacement
connections or replay companion output. Awaiting Windows input keeps the six
trust/paste instructions and the exact actor/UTC expiry.

If completed readiness expires, preserve its historical completion, remove any
current-ready claim, and offer **“Review connection refresh.”** That action
reviews a new authorization; it does not rerun old evidence or renew an old
command. Failed and unknown operations require same-operation readback and
cause-specific recovery, never a generic create retry. A role or prerequisite
restriction names who can act and why, with a safe alternative instead of an
unusable next-step button. Completion never automatically navigates or confirms.

### Operator: diagnose and manage registration availability

**Entry:** Overview → agent needing attention, or Agents → details.
**Decisions:** Read lifecycle state, permitted provisioning history and current
operation; distinguish work progressing, a required administrator action and a
terminal failure. Read permitted protection configuration to identify scope, not
to edit it. Enable/disable only when the server allows that transition.
**Outcome:** **“Registration disabled”** means new Gateway traffic is not accepted
under that state; it does not stop external hosting, delete Microsoft resources,
or retract previously submitted work. **“Registration enabled”** does not assert
that optional protection or telemetry delivery succeeded.
**Recovery:** Refresh known operation state; give an administrator the non-secret
agent/operation ID and correlation ID for actions outside this role. An Operator
cannot inspect credential metadata, issue keys, retry provisioning, complete
Registry registration, change policy, or read audit events.

### Auditor: inspect recorded actions

**Entry:** Agents → agent details → Audit.
**Decisions:** Read event type, actor, timestamp and safe details; follow only
links this role can access. Agent state and capability facts provide context;
known protection operation records can be read within the API's authorized view.
**Outcome:** **“Recorded Gateway actions”** describes audit history without
claiming an event proves downstream delivery or current provider state.
**Recovery:** **“Audit events could not be loaded”** offers a read refresh and
correlation ID. A legitimately empty history says **“No audit events returned.”**
No provisioning-history/operation page, credentials, policy edits or lifecycle
actions are implied by audit access.

### Support reader: inspect and route a problem

**Entry:** Overview or an agent detail link.
**Decisions:** Inspect returned registration metadata, current status and capability
facts. Identify which permitted detail is missing and which role must continue.
**Outcome:** A concise non-secret handoff identifies the agent, symptom, timestamp
and correlation ID. **“An administrator must complete this action”** names the
owner of an actual required action; it is not used for every read-only section.
**Recovery:** Refresh accessible reads. A restricted page explains access without
pretending the underlying data is absent. This role cannot see audit events,
provisioning history, credential metadata or editable protection settings.

### External developer: connect and submit one interaction

**Entry:** The administrator supplies the exact API URL, external agent ID and key
through the runtime's secret management process. The repository sample accepts
the secret separately from command arguments; keep that boundary.
**Decisions:** Preserve the assigned registration mapping. Replace only the sample's
model callback. Before every model call request prompt evaluation regardless of
cached local feature choices. Require HTTP 200, `allowed: true`, a non-empty
receipt and a valid future expiry; check expiry again immediately before generation.
Then submit the exact matching interaction and receipt after the model call.
**Outcome:** **“Prompt allowed by Gateway”** describes the decision for that prompt.
For ingestion, **“Accepted by Gateway”** requires inspection of processing/status
fields; HTTP 202 alone can include failed processing. **“Queued for export”** is
not **“Delivered to Agent 365”**. The sample validates matching receipt identifiers
and recognized, non-failing status/processing fields. Malformed acceptance remains
unknown and reported failure remains failure; neither triggers regeneration.
The sample still does not establish downstream delivery.
**Recovery:** Blocked, malformed, expired or unavailable enforcing evaluation stops
generation. A permitted simulation-unavailable result must say **“Simulation
unavailable”**, never Off or Enforcing. After generation or uncertain ingestion,
retain operation identifiers and reconcile; do not automatically mint new proof,
repeat a model call or replay ingestion. An administrator handles key replacement.

## Shared state language

Use the same words on Overview, Agents, details, Settings and operation summaries.
Always name the thing whose state is shown. Registration state and protection state
are separate fields, not one combined “healthy” badge.

| Label | Exact meaning and permitted evidence | Supporting copy or next action |
|---|---|---|
| Installed | The named deployment capability has an installed attestation/readback. No policy or runtime-success claim. | “This capability is available for configuration.” |
| Not installed | The capability is explicitly absent. Neutral when optional and unused. | “Install this capability before configuring it.” |
| Configured | A named setting/policy is saved; show the saved mode and current operation separately. | “Settings saved. Check current status below.” |
| Active | The Gateway registration is provisioned and enabled. Requests remain authenticated and evaluated. | “Registration active. Connect your external agent.” |
| Off | An explicit saved/requested choice disables that feature or policy. Missing data never means Off. | “This feature is off for this registration.” For shared Disabled policy: “This shared policy is saved but off.” |
| Simulation | Saved non-enforcing Purview mode. Keep evaluation availability visible. | “Evaluates policy behavior without enforcing a block.” Mode controls use “Simulation with tips” or “Simulation without tips”. Explain that tips depend on provider and client support; never fabricate a Microsoft policy tip. |
| Verifying | Relevant checks are actively running or pending, with current stage and last update. It is not an indefinite substitute for failure/expiry. | “Checking the saved policy.” / “Waiting for updated permissions.” |
| Enforcing | Purview's selected Enforce policy has current applicable readiness/certification and effective enablement. Never derive it from the desired mode alone. | “Current checks support enforcing use. Each interaction is evaluated.” Show check time/expiry and an accessible details link. |
| On | Prompt Shields is requested and currently effective according to its capability binding; this is not a Purview-style sample certification. | “Prompt Shields evaluates each prompt before generation.” Runtime errors still stop generation. |
| Unavailable | A required read, provider capability or evaluation path cannot currently be used. Preserve the saved choice and indicate the affected service. | “Purview evaluation is unavailable. Check connection and current status.” |
| Action required | Work needs a named person and specific next step; use the server's actionable state. | “Administrator action required — complete Agent 365 registration.” |
| Status unknown | No usable current result was obtained. Never infer success or Off. | “Current status could not be checked. Last successful check: {time}.” |
| Verification expired | Previously accepted evidence no longer establishes current readiness. | “Refresh the expired connection or inventory and review the current policy first. Then repeat any required approved sample check.” Show only the steps required by the reported blockers. |
| Failed | A known operation/check failed. Show the safe cause and allowed recovery. | “Configuration failed. Review the required action.” |
| Outcome unknown | A mutation may have been accepted; repetition could duplicate work. | “Check operation status before taking another action.” |
| Updates stopped | The user stopped observation or the client exhausted its bounded read-only session; the original work may still continue. | “You stopped automatic updates.” / “Automatic updates stopped after 5 minutes.” / “Resume automatic updates”. Never substitute Failed, cancel accepted work or restart the mutation. |
| Skipped | A named technical step did not run. It is not a passed verification. | Explain why it was outside this operation and which separate task, if any, still requires explicit action. |

**Precedence:** Display the saved choice separately from the live observation. For
an intentionally unused optional feature, Off/Not installed is neutral. For an
enabled feature with missing data, show Status unknown or Unavailable. A current
blocking condition overrides an old positive badge. Verifying is used only when
the server says work is continuing; action-required, terminal failure and expired
evidence get their own label and next step. A historical successful test cannot
override current profile state. Unknown new enum values use Status unknown, not a
guessed mapping.

### Request and delivery wording

| Server fact | Proposed text | Must not imply |
|---|---|---|
| HTTP 202 registration | “Registration started” | Agent is Active |
| One-time credential issued | “Gateway key issued” | External runtime is configured |
| Configuration accepted/pending | “Configuration queued” | Purview is enforcing |
| Deferred configuration awaiting exact blueprint | “Waiting for this agent's blueprint” | Consent can be reused |
| Registry POST accepted | “Finishing registration” | Final registration verification completed |
| Current registration Active | “Registration active” | Full installation or delivery acceptance |
| Allowed evaluation plus valid receipt | “Prompt allowed by Gateway” | Future ingestion guaranteed or blanket protection |
| Ingestion accepted with processing queued | “Accepted by Gateway — export queued” | Provider delivery or downstream landing |
| Ingestion `status: Failed` | “Interaction processing failed” | HTTP 202 means successful processing |
| Export attempt or endpoint acceptance | “Export attempted” / “Provider accepted request”, only if exposed | Downstream Agent 365 landing |
| Sample suite enforcement result | “Approved sample behavior verified” | Attribution to a particular matched SIT or every possible input |

## Common interaction rules

- Loading: **“Loading agent details…”** or the named section. Preserve previously
  loaded data only with its timestamp and an explicit stale/status-unknown cue.
- Empty: distinguish a returned empty list from a failed read or role restriction.
  Use **“No agents registered yet”** for an empty registry and **“No matching
  agents”** for empty filtered results, with **“Clear filters”** when applicable.
- Counts/search: the listing API now returns authoritative filtered totals and
  opaque continuation cursors, with literal case-insensitive name/external-ID
  search. Missing totals remain unavailable; never replace them with page length.
  A preview stays a preview even when its full matching count is known.
- Errors: say what failed, whether work may already have been accepted, who can act,
  and the permitted next action. Put correlation ID and technical details in a
  secondary section. Do not expose provider bodies, secrets or raw content.
- Confirmation: name the exact action and affected scope. **“Delete registration”**
  explains **“Removes this registration from the Gateway. Linked Microsoft resources
  remain.”** Keep key issuance/revocation and policy confirmation boundaries intact.
- Keyboard and narrow screens: retain visible focus, semantic controls, associated
  error text, readable status labels and all primary actions. Move focus to the
  relevant heading or validation message after a step transition. Announce updates
  without repeatedly interrupting keyboard/screen-reader work.

## Source mapping and implementation handoff

| Current source | What this design preserves or proposes |
|---|---|
| [API policies](../../src/Gateway.Api/Authorization/AuthorizationPolicies.cs), [Agents controller](../../src/Gateway.Api/Controllers/AgentsController.cs), [Operations controller](../../src/Gateway.Api/Controllers/OperationsController.cs) | Exact role split, delegated Registry action, credential/lifecycle authorization. |
| [Protection controller](../../src/Gateway.Api/Controllers/ProtectionController.cs), [runtime tests controller](../../src/Gateway.Api/Controllers/PurviewRuntimeTestsController.cs), [System controller](../../src/Gateway.Api/Controllers/SystemController.cs) | Protection read/mutation boundaries, review/confirmation, administrator runtime workflow and system defaults. |
| [Navigation](../../src/Gateway.AdminUi/Components/Layout/NavMenu.razor), [Getting started](../../src/Gateway.AdminUi/Components/Pages/SetupCenter.razor), [Overview](../../src/Gateway.AdminUi/Components/Pages/Home.razor) | Existing entry routes; propose less technical next-step copy and accurate result-set summaries. |
| [Registration](../../src/Gateway.AdminUi/Components/Pages/RegisterAgent.razor), [agent details](../../src/Gateway.AdminUi/Components/Pages/AgentDetails.razor), [operation status](../../src/Gateway.AdminUi/Components/Pages/OperationStatus.razor) | Key-before-navigation, role-aware sections, lifecycle guards and recoverable operation IDs. |
| [Settings](../../src/Gateway.AdminUi/Components/Pages/Settings.razor), [protection mapping](../../src/Gateway.AdminUi/Models/AgentProtectionUiMapping.cs), [readiness panel](../../src/Gateway.AdminUi/Components/Shared/ProtectionReadinessPanel.razor) | Existing protection choices and evidence; propose focused sections and uniform wording. |
| [Status pill](../../src/Gateway.AdminUi/Components/Shared/StatusPill.razor) | Current `NotInstalled` displays “Unavailable”; proposed vocabulary explicitly separates these states. No production mapping change is claimed here. |
| [Effective feature evaluator](../../src/Gateway.Application/Protection/ProtectionEffectiveFeatureEvaluator.cs), [readiness DTO](../../src/Gateway.Contracts/Dtos/ProtectionReadinessDto.cs) | Current authoritative feature/readiness evidence; UI must not invent enforcement. |
| [Runtime report](../../src/Gateway.AdminUi/Components/Pages/PurviewRuntimeTestStatus.razor), [sample runner](../../src/ExternalAgent.Sample/SampleInteractionRunner.cs), [sample entry](../../src/ExternalAgent.Sample/Program.cs) | Read-only report recovery, pre-model receipt gate, exact prompt binding, separate secret entry and no blind retries. |
| [Local setup pages](../../tools/Gateway.Setup/Components/Pages), [execution coordinator](../../tools/Gateway.Setup/Services/BootstrapExecutionCoordinator.cs), [bootstrap guide](../../bootstrap/README.md) | Local installer/portal distinction; target-bound plan, eligible resume and verified endpoint handoff. |

This document supplies the journey/language contract. Screen layouts and exact
component copy are specified in [screen design](screen-design.md); behavior to
exercise is specified in [acceptance scenarios](acceptance-scenarios.md). These
are design and validation inputs, not additional completion records. Production
changes belong to M3/M4, with release and hosted verification retaining their
later milestone scope.
