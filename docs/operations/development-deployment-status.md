# Development deployment status

Last updated: 2026-09-06 (Asia/Seoul).

This checkpoint separates deployed evidence from source claims. It intentionally
contains no subscription, tenant, resource-group, application, principal,
registration, image-digest, correlation, credential, token, prompt, response, or
provider-body value. Environment-specific evidence belongs in ignored
`.bootstrap/` output or an access-controlled operator evidence store.

For unfinished source work after a fetch, pull, or fresh clone, begin with the
tracked [agent continuation checkpoint](../agent-continuation.md). Git alone does
not transfer the ignored state required to Resume an existing deployment.

## Current live stop: Graph sign-in before fresh deployment

The corrected source is committed and pushed to canonical `main`. All five hosted
jobs passed: Build and Test, Validate Bicep, and Bootstrap on Windows, macOS, and
Ubuntu. The operator renewed authority for the reviewed fresh deployment and full
Gateway E2E. This session does not need another deployment approval; that authority
and the exact target remain in ignored local operator evidence and do not transfer
with Git.

Visible Setup imported the reviewed fresh configuration and completed Azure
What-If, then stopped at its read-only Agent ID blueprint check. Independent
readback found Graph HTTP 401, `InvalidAuthenticationToken`, and a claims challenge.
No Apply was accepted and no resources were created for this target. The official
Azure CLI browser sign-in was started. Automatic Computer Use policy then stopped
Windows browser inspection because the current URL could not be verified; no
further browser automation was attempted.

The first unfinished action is to complete that official Microsoft sign-in, verify
Graph access in the exact tenant, refresh Plan in visible Setup, and Apply under
the existing authority. Continue through canonical Verify, real Admin UI sign-in,
two blueprint-bound registrations, delegated Registry completion, independently
observed Agent 365 landing, Prompt Shields allow/block, and blueprint DLP
allow/block. The operator permits blueprint creation or compatible reuse; reconcile
the existing seed before creating additional objects. Deployment and all live E2E
claims remain open. No password, token, or Gateway key is stored in the handoff.

## Preserved deployment and accepted startup correction

The authorized replacement completed its first bounded database recovery with
exactly one successful execution and no automatic retries. Independent Azure
readback verified the corrected immutable image, preserved original failed job,
and restored original SQL administrator. The original accepted plan and workload
image evidence remain unchanged. Eleven of nineteen stages are complete.

Visible Setup's read-only Resume review passed the source, identity, infrastructure,
image, and private-network checks, then stopped at the database-stage API readiness
request. No Resume authorization was issued and no deployment mutation followed.
Detailed revision health showed a restarting API. Its strict startup validator
rejected enabled Prompt Shields because the inert deployment precedes capability
attestation. This is an API startup ordering defect, not a failed database recovery.

The source correction gates API Prompt Shields on the runtime deployment phase.
Selected Content Safety infrastructure, RBAC, and endpoint outputs remain prepared
during inert deployment. Exact capability validation, provider fail-closed behavior,
SQL evidence checks, and API readiness requirements remain enforced. The regression
first reproduced three failures. The six focused phase/template regressions and
22 Prompt Shields tests, including three actual HostBuilder startup cases, passed.
The clean 900-file export passed Release with zero warnings/errors, all eight .NET
projects (2,008 tests), and the complete bootstrap gate (876 passed, zero failed,
7 skipped; 20 PowerShell files, 2 JSON files, 28 Bicep templates, 3 parameter files).
All nine formatting targets, Windows/POSIX launcher smoke, metadata/private-path
checks, full ledger audit, and fresh independent correction source review passed.
All five hosted jobs passed for the containing source correction commit.

Independent review confirmed that no existing supported command accepts this new
source generation after completed source-pinned database recovery. Preserve that
deployment, its state, jobs, identities, accepted snapshots, and credentials. Do not
replay recovery or bypass the source and readiness guards. A new isolated deployment
has now received exact-target authority in the active operator session.

Deployment and live E2E remain unfinished. Admin UI sign-in, two blueprint-bound
registrations, delegated Registry completion, Agent 365 landing, Prompt Shields
allow/block, and blueprint-specific DLP allow/block remain unproved. Environment
identifiers and receipts remain in ignored operator evidence.

## Capability Boolean correction and offline evidence

A separately authorized clean beta.2 bootstrap reached the inert deployment, where
ARM emitted `BootstrapCapabilities__Enabled` as `False` but the verifier expected
`false`. The verifier now uses the existing ARM Boolean text helper for both
`True` and `False`. Ordinal comparison, opposite-value rejection, secret-reference
rejection, and all nineteen capability fields remain enforced. Templates, images,
application behavior, and accepted-state guards are unchanged.

The executable regression first failed for both Boolean values, then all fourteen
container-configuration tests passed. Fresh independent source and recovery review
accepted the correction. Release passed with zero warnings/errors, and all eight
.NET test projects passed again (2,004 tests). The complete bootstrap gate passed
848 tests with zero failures and 7 skips, plus all 28 Bicep templates and 3 parameter
files. All nine format targets and metadata/private-path checks passed. The clean
898-file export passed Release, all 2,004 .NET tests, source/Bicep, the 14-test
regression, and Windows/POSIX launcher smoke. Production-source fingerprints match
the canonical candidate. All five correction-specific hosted jobs passed before
the separately authorized replacement deployment.

The older full acceptance table below records the pre-deployment baseline. It is
not evidence of a completed deployment or passed live E2E.

## What is deployed and verified

A user-operated bootstrap run provisioned a gateway into an empty resource group
and reached all nineteen steps `Completed`. Verified against that live
deployment:

- one bootstrap-owned Azure resource group, provisioned only through the
  `gateway` launcher;
- Azure SQL initialized with Microsoft Entra authentication only;
- immutable API, worker, Admin UI, and database-migrator images;
- healthy API readiness endpoints and working Admin UI sign-in as the deployment
  owner;
- six external agents registered across three blueprints, two agents per
  blueprint, exercising both the create-new and use-existing agent identity
  modes;
- the seven persisted provisioning workflow stages driven over the v3 queue
  boundary;
- the external-agent data-plane surface returning its documented status codes for
  prompt evaluation, interaction submission, single activity submission, and
  batch activity submission, including the required idempotency-key and
  two-call receipt handshake;
- per-sink Agent 365 export acceptance, read from the `results` array rather than
  from `partialSuccess` alone, with every submitted span accepted; and
- distinct telemetry role names for the API and the provisioning worker, so the
  two hosts can be told apart in Azure Monitor.

Prompt Shields was verified enforcing per agent prompt, which is the intended
scope: Prompt Shields is evaluated per agent request, while Purview DLP applies
at blueprint level.

The deployed build proved that scope behaviourally, by blocking one agent's
prompt without affecting its blueprint siblings, but it did not record *which*
Agent 365 identity a verdict belonged to. A source correction now carries the
calling agent's Agent 365 agent ID and blueprint ID into every evaluation, tags
them onto the trace, and persists them on the stored evaluation record, so a
verdict answers "which agent made this call" on its own. An agent whose Agent
365 provisioning has not completed still receives a real verdict; the missing
identity is recorded as absent and logged, never backfilled with a placeholder.
The identity is deliberately not sent to Azure AI Content Safety, which has no
field for it. This is a source correction that has not been deployed. Treat
per-verdict identity attribution as unproven until a deployed build shows a
non-null `Agent365AgentId` on `dbo.PromptEvaluationRecords` for a live
evaluation.

Agent 365 activity attribution was verified in the Microsoft 365 admin center.
Each agent's own Activity tab reported a session count equal to the number of
allowed invocations made against that agent, and a prompt that Prompt Shields
blocked produced no session at all. That is per-agent attribution, not a pooled
total, and it confirms that blocking happens before any Agent 365 activity is
emitted.

Note one admin-center inconsistency that is not a gateway defect: the agent list
view's rollup columns for active users, total sessions, and last used can still
read empty while the per-agent Activity tab shows live data. The list view and
the detail tab are served by different aggregates. Read the per-agent tab.

Agent 365 interaction logging was verified in the Purview unified audit log. A
portal audit search over a window that fully covers the exercised traffic,
filtered by Agent 365 **record type** rather than by operation name, completed
and returned eighty-six records: forty-three `InvokeAgent`, thirty-six
`InferenceCall`, and seven `ExecuteToolBySDK`. Those are the gateway's own
exported spans arriving in the tenant audit store, and they cover every operation
the gateway emits, tool activity included. Interaction logging is met.

Tool activity took two searches to find, because its operation name is
`ExecuteToolBySDK` and not `ExecuteTool`. An earlier revision of this checkpoint
recorded zero tool records and left the cause undetermined between a Microsoft
audit coverage gap and a defect in the gateway's tool child span. It was neither:
the search filtered on a name the audit store does not use, so it matched
nothing. The record-type search found all seven, and eighty-six minus the
seventy-nine that the operation-name search returned is exactly that count.

The record-type search also returned zero guardrail records, which settles that
question, because a record type is chosen from a picker and cannot be misspelled
the way an operation name can. The absence is expected rather than a gap. The
gateway's activity type enumeration has no guardrail member, so the gateway
cannot emit a guardrail activity at all, and it calls Prompt Shields as Azure AI
Content Safety, which sits outside Agent 365. An Agent 365 guardrail audit record
could only be produced by Agent 365's own guardrail evaluation, which the gateway
never invokes. Do not treat the absence as a defect, and do not add a guardrail
operation to the exporter to manufacture one.

Those observations prove the deployed build that produced them. They do not
prove that later source changes are deployed.

## What is not yet proven

Fail closed on each of these; none may be reported as met.

The source direction has changed since this deployment. Bootstrap now prepares
Agent 365, Prompt Shields, and Purview capabilities, while role-aware Gateway Admin
Settings owns mutable protection configuration and readiness. Phases 1–4 of the
[protection settings plan](../architecture/protection-settings-plan.md) passed
offline acceptance after fresh independent review. Existing deployed evidence below
does not prove that experience. The corrected source passed exact-commit hosted CI and received fresh-target
authority. Its current Graph sign-in stop is recorded at the top of this checkpoint.

- **Purview DLP at blueprint level.** No blueprint-scoped DLP verdict has been
  observed, so this remains unmet. Two coupled constants previously pinned
  `Purview__Enabled` to false on every deployment: the policy evidence builder
  reported the adapter as disabled even after the collection, the DLP policy,
  and the DLP rule passed exact typed readback, and the deployment-evidence
  validator expected that same false value, so it would have rejected a
  deployment that enabled it. Being mutually consistent, neither ever failed a
  check. Both now follow the reviewed configuration, but that is a source
  correction which has not been deployed. A second blocker sat behind the first
  and would have stopped the very next run: a step that completed while Purview
  was disabled records `configured: false`, and the validator rejected that as a
  mismatch while the anti-replay guard refused to run the step again, so the run
  failed and flipped the step to `Failed`, after which the reconciler found no
  tenant object to recover and the deployment could not proceed at all. The
  guard now scopes itself to evidence of an actual prior authoring attempt,
  which the disabled early return provably is not, so a no-op completion simply
  runs while a real prior mutation still fails closed. Provisioning the Purview
  policy-automation application and certificate is *not* a prerequisite here:
  bootstrap already authors the blueprint-scoped DLP policy over the operator's
  interactive session, and registering an agent against an *existing* blueprint
  never enters the profile-provisioning path. That automation identity is
  required only to create a *new* protected blueprint, where the worker must
  author policies unattended. Enabling the adapter makes the runtime path
  reachable, not correct: evaluation stays per-agent opt-in and fails closed,
  and a managed identity lacking the Purview Graph roles still fails the
  request. Treat the feature as unproven until a live allow and block pair is
  observed on a deployed build.
- **Azure Monitor mirror completeness.** The Agent 365 sink is proven per sink.
  The mirror is now *instrumentable* but is still not *proven*. The counter
  `gateway.observability.azure_monitor.emitted_events` previously hardcoded its
  `gateway.export.result` dimension to `emitted` and incremented even when no
  span had been created, so it could not distinguish an event that was never
  recorded from one recorded and then lost in export. That dimension now carries
  the real outcome, `recorded` or `not_recorded`, and the worker logs a warning
  whenever an event whose idempotency claim was already consumed produced no
  span, because such an event can never be mirrored again. This is a source
  correction that has not been deployed. Treat the mirror as lossy until a live
  emitted-versus-mirrored count check passes on a deployed build: query the
  counter split by `gateway.export.result` and confirm `not_recorded` is zero
  over the same window as the exercised traffic.
- **Defender agent inventory for the current agents.** The Defender advanced
  hunting inventory table does carry the gateway's own platform value alongside
  the first-party agent platforms, which proves gateway-created agent identities
  reach Defender. It is a periodic snapshot, not a live feed: the most recent
  snapshot predated the current registrations by several hours, so those specific
  agents were legitimately not in it yet. Absence within one snapshot interval is
  latency, not rejection.
- **Defender cloud app interaction rows.** The advanced hunting table that would
  carry these rows has ingested nothing tenant-wide for the entire retention
  window. That emptiness is an ingestion gap in the table itself, not evidence
  that gateway spans were rejected, and it must not be read as either
  confirmation or refutation.

When reading either portal, note that timestamps render in the signed-in
operator's local time zone while the gateway's own evidence is in UTC. Compare
them by converting explicitly; a snapshot that looks current can be most of a
day old.

Purview audit search additionally distinguishes **record types** from **operation
names**, and for Agent 365 the two spellings differ in a way that follows no
single rule. The record types are `AIInvokeAgent`, `AIInferenceCall`,
`AIExecuteTool`, and `AIGuardrail`. The operation names are `InvokeAgent`,
`InferenceCall`, and `ExecuteToolBySDK`: the first two are the record type minus
its `AI` prefix, the third is not, so an operation name cannot be derived from a
record type and must be read off an actual record. A name the audit store does
not use returns zero rows with no error, which reads exactly like an ingestion
failure. Every "missing records" finding in earlier revisions of this checkpoint
was this mistake — twice a record-type spelling was entered in the "Activities -
operation names" box and returned zero, and once `ExecuteTool` was entered and
silently omitted the seven tool records that were present all along.

Prefer filtering by record type, because the picker offers only valid values and
so cannot be misspelled. Before concluding anything from a zero-result search,
run the same window with every filter cleared as a control: if the unfiltered
control returns rows, the pipeline is ingesting and the zero is a filter error,
not latency. Confirm what was actually submitted from the results-page URL,
because the search form resets to its defaults as soon as the search is queued.

## Relationship to the current source tree

The verification and telemetry corrections listed below are **deployed** in the
current development gateway, and their live outcomes are recorded above:

- the Agent 365 exporter proves acceptance from the per-sink statuses in
  `results` and fails closed with a bounded reason, instead of trusting
  `partialSuccess` alone;
- the tracer records every gateway span regardless of the caller's sampling
  decision, because an external agent arriving with `sampled=0` was previously
  able to suppress the gateway's own audit span;
- the Azure SDK activity sources are subscribed, so Service Bus and Blob
  dependencies are no longer invisible; and
- each host reports its own `service.name`, so API and worker telemetry can be
  told apart in Azure Monitor.

A source revision is not deployed evidence until immutable image digests, exact
resource readbacks, health checks, queue state, and a bounded registration are
recorded for that revision. Anything committed after this checkpoint is
undeployed until the next clean provision records its own readbacks.

## Shipping a source change to an existing deployment

Bootstrap is provision-once by design. Once a deployment has recorded durable
state evidence, its accepted source is immutable: Plan routes to Resume, and
Resume refuses when the working tree no longer matches the accepted source
fingerprint. The engine states the supported remedies itself — restore the exact
prior source, or choose a distinct project/resource group.

There is therefore **no in-place application upgrade path, and none should be
added without an explicit decision**, because mixing source generations inside
one deployment state is exactly what the guard exists to prevent. To deploy
changed application source, run a new bootstrap under a new unused deployment
identity. Do not delete `.bootstrap/` state to force progress, and do not point
fresh state at an existing resource group.

Because each deploy cycle is a full clean provision, batch pending source
corrections and deploy them together rather than one per cycle.

Pending that batch, in commit order:

- transient Microsoft Graph 400 handling when establishing a blueprint principal;
- the existing-blueprint picker remaining usable past forty blueprints;
- the honest `recorded` / `not_recorded` outcome on the Azure Monitor mirror;
- per-agent Prompt Shields identity attribution, which also adds
  `infrastructure/sql/20260903_prompt_evaluation_agent_identity.sql`;
- the Purview runtime adapter following the reviewed configuration once the
  policy objects pass exact typed readback;
- the setup wizard defaulting to the recorded deployment identity, so accepting
  the defaults reconfigures that deployment instead of silently naming a new
  one;
- the Purview anti-replay guard scoping itself to a real prior authoring
  attempt, so enabling Purview after a disabled no-op completion can proceed; and
- completed-step validator failures naming only the exact mismatched property path,
  while expected and actual resource values remain suppressed;
- Registry creation emitting one POST only and treating every result except
  documented `201 Created` as failure or exact-ID-recoverable ambiguity;
- Prompt Shields using managed identity only, without a default developer or
  environment credential chain; and
- active child Agent Identity object IDs being database-unique through an ordered,
  fail-closed migration that does not rewrite registrations.

The protection-settings implementation is now part of the undeployed source batch:
capability presets/bootstrap, Admin UI, API, governance SQL, provider adapters,
packaged Windows companion, dedicated queue/worker, effective readiness, and tests.
The current deployed Gateway contains none of it.

The combined beta.2 source passed integrated offline acceptance and fresh
independent security/UI source review, followed by a clean export containing all
intended new files. The exact counts and validation boundary are below. This
replaces the earlier failed review and concurrent focused evidence as the source
acceptance record. None of it is deployment or live-readiness evidence.

Two items in the pending batch change the database schema. Per-agent Prompt Shields
identity attribution adds
`infrastructure/sql/20260903_prompt_evaluation_agent_identity.sql`, and active child
identity uniqueness adds
`infrastructure/sql/20260905_active_agent_identity_uniqueness.sql`. The next
provision applies both in order and records a different schema fingerprint. That is
expected, not drift.

## Offline gate

| Gate | Final result |
|---|---:|
| Release build | 0 warnings, 0 errors |
| Gateway.UnitTests | 805 passed |
| Gateway.AdminUi.Tests | 217 passed |
| Gateway.Setup.Tests | 255 passed |
| Gateway.ObservabilityRuntime.Tests | 232 passed |
| Gateway.ArchitectureTests | 131 passed |
| Gateway.IntegrationTests | 107 passed |
| Gateway.EndToEndTests | 116 passed |
| Gateway.SecurityTests | 141 passed |
| **.NET total** | **2,004 passed, 0 failed** |
| Pester | 846 passed, 0 failed, 7 skipped |
| Format | All nine targets passed |
| Independent security and UI source review | Passed; no remaining actionable findings |
| Clean export | Release, all eight test projects, canonical bootstrap gate, layout and launcher smoke passed |

Canonical source gate: 20 PowerShell files and 2 JSON files, with 28 Bicep templates and 3 parameter files compiled, with Pester behavior tests.


Hosted validation exposed Windows-only fixture paths and platform differences
in passwordless PKCS12 verification. The tests now use a native temporary path and
accept both documented null and empty password encodings independently for the
MAC, safe contents, and private key. All eight synthetic encoding combinations
pass; nonempty-password and public-only packages are rejected. The actual export
must retain the exact certificate and prove its matching private key by an
in-memory signature. Both affected files passed again (11 tests, zero
failures/skips) in the canonical checkout and clean export; fresh independent
review of the encoding correction passed. Production source, test counts, and UI
contracts are unchanged, so the earlier full integrated results above remain
applicable alongside this incremental evidence. All five hosted jobs passed for
the certificate-proof correction before the separately authorized live attempt.
The subsequent Boolean-verifier correction below requires its own acceptance.

The fresh independent review passed the combined source after explicitly
rechecking all four original findings: shared API/worker runtime identity and
token subject, exact capability/runtime binding, cancellation-owned process
termination, and provider-ID-bound KYD/DLP updates with exact readback and
ambiguous-outcome recovery. It also rechecked the exact 19-key
`BootstrapCapabilities` startup materialization and subsequent integration
corrections to bootstrap identity attestation, API credential guards, current
tenant/SIT readiness, and Settings action compatibility. No earlier review was
reused as acceptance.

UI acceptance uses the full bUnit suite and fresh independent source review.
The user explicitly accepted that evidence after automatic browser policy blocked
local inspection. Desktop and narrow-width browser inspection was waived, not
reported as executed. AgentDetails distinguishes effective protection from
selected-profile readiness. Settings uses the supported UploadText Block rule
for both policy modes, and only Enforce can request runtime allow/block proof.


Run each of the eight test projects individually: the shipping solution contains
no tests, so a solution-scoped test command can succeed without executing any.
Use `tools/Test-BootstrapSource.ps1 -RunPester -CompileBicep` for the canonical
PowerShell/Pester/Bicep coverage, and verify formatting for the solution plus all
eight test projects. Check hosted CI against the exact release commit before any
separately authorized live task.
Earlier deployments and their evidence remain preserved. The most recent stopped
deployment has eleven completed stages, one seed blueprint, and independently
verified database recovery and SQL administrator restoration. Its API startup
ordering correction is accepted in source, but that source cannot be resumed into
the completed source-pinned recovery. Use the authorized fresh target described
at the top of this checkpoint. Do not edit accepted state, replay database jobs,
finalize SQL, or clean up earlier deployments. Exact receipts and current operator
authority remain local; neither transfers through Git or documentation.


## Optional protection evidence

Prompt Shields reached Azure AI Content Safety successfully. The combined Prompt
Shields plus Purview request failed closed at the Purview dependency.

Directory readback showed the intended Purview Graph app-role assignments, but a
safe in-memory check showed that the managed-identity token did not yet contain
the required Purview roles. No token was printed or persisted. Therefore:

- policy-object readback is configuration evidence only;
- directory role assignment is not token-role evidence;
- the deployed build was provisioned with `Purview__Enabled=false`, which was
  correct for it; current source instead derives that flag from the reviewed
  configuration once the policy objects pass exact typed readback;
- Purview runtime readiness requires a fresh managed-identity token-role check and
  a bounded allow/block request; and
- the repository does not claim response-side inline DLP enforcement.

Follow the [Purview runbook](purview-setup-runbook.md) for the post-bootstrap
configuration and validation boundary.

## Live-action boundary

- Do not delete or re-provision the current development resource group without a
  fresh, explicit user authorization for that specific group. Authorization given
  for one deployment's teardown does not carry to the next.
- Do not run a new bootstrap against an existing gateway-owned resource group or
  adopt it from a new local state directory.
- Do not access, replay, or dispose of retained dead-letter evidence without a
  separately authorized incident procedure.
- Do not expose or attempt to recover a one-time Gateway key.
- Do not describe current source as deployed until its own readbacks are recorded.
- Do not enable Purview runtime enforcement merely because directory assignments
  or policy objects exist.
- Do not treat an empty telemetry table as proof that an export was rejected.
- Keep unfiltered provider text in ignored `.bootstrap/diagnostics/` only; it can
  contain identities and headers and must never be pasted into an issue, a chat,
  or a shared log.

## Evidence required after a future deployment

Record environment-specific details outside the public repository, then summarize
only the non-sensitive outcome here:

1. accepted source/configuration/plan fingerprints;
2. immutable deployed image digests and active revisions;
3. exact identity, role, federation, network, and database readbacks;
4. API and Admin UI health;
5. active/scheduled/dead-letter counts for every owned queue;
6. two bounded registrations through `Active` without duplicate Registry mutation,
   each creating a new blueprint;
7. one external agent connected to each blueprint;
8. per-agent Agent 365 export acceptance, not merely an HTTP status;
9. Prompt Shields allow/block and Purview DLP allow/block results for both
   blueprints, clearly separated; and
10. the next safe operator action.

The durable deployment lessons are reflected in code and runbooks: private SQL
requires private execution reachability, ACR pull identity must exist before first
workload pull, an empty database is the only automatic initialization target,
unknown Registry POST outcomes are GET-only, optional protection readiness must
not close the core registration path, and a success status code from a dependency
is never by itself proof that the dependency accepted the payload.
