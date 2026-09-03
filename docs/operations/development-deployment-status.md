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
  boundary; and
- the external-agent data-plane surface returning its documented status codes for
  prompt evaluation, interaction submission, single activity submission, and
  batch activity submission, including the required idempotency-key and
  two-call receipt handshake.

Prompt Shields was verified enforcing per agent prompt, which is the intended
scope: Prompt Shields is evaluated per agent request, while Purview DLP applies
at blueprint level.

Those observations prove the deployed build that produced them. They do not
prove that later source changes are deployed.

## What is not yet proven

Fail closed on each of these; none may be reported as met.

- **Agent 365 export acceptance.** The exporter received HTTP 200 from the
  observability ingest endpoint, but a 200 is not proof of ingestion. Microsoft
  documents that a whole-request routing decision can leave
  `partialSuccess.rejectedSpans` at `0` while `results` reports every span
  rejected. The deployed build only inspected `partialSuccess`, so acceptance was
  never actually established.
- **Purview DLP at blueprint level.** Purview remains disabled by configuration,
  so no blueprint-scoped DLP verdict exists.
- **Microsoft 365 admin center activities.** The Activity surface showed no rows
  for a registered agent. Note that admin-center activity metrics are documented
  as supporting a specific set of agent types, which does not currently include a
  custom gateway platform, so this surface may be legitimately unavailable rather
  than merely empty.
- **Purview and Defender interaction logs.** The Defender advanced-hunting table
  that would carry these rows has ingested nothing tenant-wide since early
  August 2026. That emptiness is an ingestion gap in the table itself, not
  evidence that gateway spans were rejected, and it must not be read as either
  confirmation or refutation.

## Relationship to the current source tree

The current source contains verification and telemetry corrections that are
**not deployed**:

- the Agent 365 exporter now proves acceptance from the per-sink statuses in
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
recorded for that revision.

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

All eight .NET test projects pass 1,713 tests with zero failures, and the
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
