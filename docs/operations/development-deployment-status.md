# Development deployment status

Last updated: 2026-09-03 (Asia/Seoul).

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

Those observations prove the deployed build that produced them. They do not
prove that later source changes are deployed.

## What is not yet proven

Fail closed on each of these; none may be reported as met.

- **Purview DLP at blueprint level.** Purview remains disabled by configuration,
  so no blueprint-scoped DLP verdict exists. Enabling it also requires bootstrap
  to provision the Purview policy-automation application and certificate, which
  it does not yet do.
- **Azure Monitor mirror completeness.** The Agent 365 sink is proven per sink,
  but the parallel Azure Monitor mirror is not yet measurable: nothing asserts
  that a mirrored span exists for every emitted event. Treat the mirror as
  lossy until an emitted-versus-mirrored count check passes.
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
- **Purview unified audit records.** A portal audit search over a window that
  fully covers the exercised traffic, filtered to the four documented Agent 365
  activity operations, completed successfully and returned zero records. That is
  **not** evidence of absence. The search completed roughly forty minutes after
  the traffic, and Microsoft documents agent audit entries as taking thirty
  minutes to two hours to appear, with no committed upper bound. Re-run the same
  search at least two hours after the traffic before drawing any conclusion, and
  include both documented spellings of the guardrail operation, because the audit
  activities table and the Management Activity API schema disagree on whether the
  recorded operation is the bare guardrail name or its applied form.

When reading either portal, note that timestamps render in the signed-in
operator's local time zone while the gateway's own evidence is in UTC. Compare
them by converting explicitly; a snapshot that looks current can be most of a
day old.

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

## Offline gate

All eight .NET test projects pass 1,734 tests with zero failures, and the
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
