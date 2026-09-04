# Development deployment status

Last updated: 2026-09-04 (Asia/Seoul).

This checkpoint separates deployed evidence from source claims. It intentionally
contains no subscription, tenant, resource-group, application, principal,
registration, image-digest, correlation, credential, token, prompt, response, or
provider-body value. Environment-specific evidence belongs in ignored
`.bootstrap/` output or an access-controlled operator evidence store.

For unfinished source work after a fetch, pull, or fresh clone, begin with the
tracked [agent continuation checkpoint](../agent-continuation.md). Git alone does
not transfer the ignored state required to Resume an existing deployment.

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

- **Purview DLP at blueprint level.** Purview remains disabled by configuration,
  so no blueprint-scoped DLP verdict exists. Enabling it also requires bootstrap
  to provision the Purview policy-automation application and certificate, which
  it does not yet do.
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
- the honest `recorded` / `not_recorded` outcome on the Azure Monitor mirror; and
- per-agent Prompt Shields identity attribution, which also adds
  `infrastructure/sql/20260903_prompt_evaluation_agent_identity.sql`.

That last item is the only one in the batch that changes the database schema, so
the next provision will apply a new migration script and record a different
schema fingerprint. That is expected, not drift.

## Offline gate

All eight .NET test projects pass 1,748 tests with zero failures, and the
solution build completes with zero warnings and zero errors under
`-warnaserror`.

Run the test projects individually. `src/A365Gateway.slnx` deliberately contains
only shipping projects, so a solution-scoped `dotnet test` matches no test
project, produces no output, and exits successfully without running anything.
Treat an empty test run as a failure to execute, never as a pass.

On Windows, a POSIX shell harness may strip the NuGet and `PATHEXT` environment
variables that `dotnet`, `git`, and `az` require; re-export them before invoking
any gate. Invoke PowerShell as `pwsh -NoProfile -File <path>` rather than with an
inline `-Command` string.

## Optional protection evidence

Prompt Shields reached Azure AI Content Safety successfully. The combined Prompt
Shields plus Purview request failed closed at the Purview dependency.

Directory readback showed the intended Purview Graph app-role assignments, but a
safe in-memory check showed that the managed-identity token did not yet contain
the required Purview roles. No token was printed or persisted. Therefore:

- policy-object readback is configuration evidence only;
- directory role assignment is not token-role evidence;
- the current source correctly keeps `Purview__Enabled=false` during bootstrap;
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
6. one bounded registration through `Active` without duplicate Registry mutation;
7. per-sink Agent 365 export acceptance, not merely an HTTP status;
8. optional Prompt Shields and Purview results, clearly separated; and
9. the next safe operator action.

The durable deployment lessons are reflected in code and runbooks: private SQL
requires private execution reachability, ACR pull identity must exist before first
workload pull, an empty database is the only automatic initialization target,
unknown Registry POST outcomes are GET-only, optional protection readiness must
not close the core registration path, and a success status code from a dependency
is never by itself proof that the dependency accepted the payload.
