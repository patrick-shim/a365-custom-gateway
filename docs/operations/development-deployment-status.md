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

## Current delivery: stopped for model handoff

The operator stopped live work because model credits were exhausted and requested
this handoff. The fully running Gateway has **not** been delivered. Do not restart
deployment automatically from this checkpoint; continue when the operator resumes
the task. Exact target, original authorization, configuration and recovery evidence
remain in ignored local operator records and do not transfer through Git.

The active Azure bootstrap has thirteen of nineteen stages completed. Its original
Purview prerequisite failure was a malformed directory-role query. The corrected,
reviewed recovery completed and independently verified the exact Exchange and
Compliance Administrator grants on the existing owned automation identity.
Its certificate operation remains `Started`, with no completion receipt.

Read-only evidence shows that the exact Key Vault certificate-secret deployment
succeeded, while the pinned Entra application still has zero key credentials.
The exact application audit event reports a failed `Update application` with
`Microsoft.Online.Workflows.ValidationException`. This is a partial certificate,
not a missing certificate and not a completed recovery. No secret value was read
for diagnosis. Preserve the secret, both grants, original accepted snapshot,
thirteen completed stages and the recovery operation record. Do not rotate,
recreate, clear or replay the certificate operation, or rerun the whole identity
Ensure function. The existing recovery rejects this partial state by design.

Before that live attempt, the minimal recovery source passed independent review,
Release with zero warnings/errors, all 2,008 .NET tests, 928 Pester tests with seven
skips, 28 Bicep templates and three parameter files, formatting and clean-export
Windows/POSIX launcher checks. The PKCS12 proof correction also passed independent
review; its bounded zero-padding acceptance retains MAC, key and certificate proof.
These are evidence for the minimal recovery source, not the combined handoff source.

The reviewed Windows executor, worker transport, private publisher, package
inspector, Bicep and tests have now been promoted into canonical source. Required
implementation is no longer held only in an ignored export. Canonical recovery and
diagnostic privacy corrections were preserved during promotion. The host/client,
publisher and package-inspector boundaries previously passed independent review
with 66, 49 and 29 focused tests; two additional package-builder source-binding
tests passed, with 31 combined package tests and independent review. Deployment
integration, dedicated identity creation, package publication, upgrade receipt,
fresh-bootstrap wiring and actual Windows/provider proof remain unfinished.
The old package must be rebuilt against the final source before publication.

Promotion changes the source fingerprint. It does not widen or complete the
preserved minimal recovery authorization. The combined source must not be deployed
as a finished Full evaluation release. A local Windows host startup check was
blocked by automatic tool policy and remains unverified. The new source has not
been deployed; final combined validation and hosted CI are reported separately.

No new registration, delegated Registry completion, worker-verified Active,
independent Agent 365 landing, Prompt Shields allow/block or DLP allow/block has
passed for this target. All remain required after deployment and Windows integration.
Use the shared model handoff protocol and exact first unfinished action below or
in the continuation checkpoint. Canonical `main` is the sole checkout; the old
linked worktree, branch and verified-empty worktree parent were retired. Credentials
and runtime evidence remain outside Git.

## Handoff validation

The combined handoff source passed Release with zero warnings and errors, all 2123
.NET tests across eight projects, 31 package/source-binding Pester tests, source
structure checks, document/link/private-path checks and independent handoff review.
The earlier architecture failure was a stale expectation of the removed local
provider; its assertion now expects the reviewed remote provider and all affected
tests pass. The first build was blocked only by the owned idle Setup executable;
stopping that host resolved the lock. Final full bootstrap/export gates and hosted
CI remain pending for this combined source. No live gate was closed by this handoff.

## Historical preserved deployment and startup correction

The following retained-target evidence predates the active thirteen-stage attempt.
It is not the current next action. Follow the current delivery block above and
the single continuation checkpoint for execution.

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

## Historical capability Boolean correction and offline evidence

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

## Historical deployed and verified evidence

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

## Current acceptance and upgrade boundary

The active deployment is the thirteen-stage attempt described at the top of this
checkpoint. No previous deployment's telemetry, registration or protection result
closes its remaining gates. Detailed historical telemetry and troubleshooting
chronology remain in Git history.

Bootstrap prepares shared capabilities only. It never selects a sensitive
information type or authors Know Your Data or DLP policy. Gateway Settings owns
those operations and requires exact provider verification of its automation
authority. Creating or reusing a compatible blueprint does not bypass DLP profile
readiness. Both compliance providers require the reviewed Windows execution path;
the Linux worker's module installation proves neither connection nor authoring.

The accepted bootstrap source and completed stage evidence remain immutable.
Ordinary Resume cannot silently adopt changed source. The active attempt stopped
inside the [narrow prerequisite recovery](purview-prerequisite-recovery.md) with a
partial certificate. That command cannot repair this state. Diagnose the failed
publication and review an exact repair before any recovery completion or Resume.
No new resource group, database initialization or replacement identity is authorized
by this handoff.

A separate reviewed Windows executor upgrade is being implemented. It must bind
the original accepted plan, exact existing resource/identity/SQL evidence, new
immutable package and worker image, scoped roles and private network readback in
its own receipt. It must not rewrite the original plan or stage history. Follow
[Windows execution](../architecture/purview-windows-executor.md) for the concrete
unfinished integration. Do not improvise an upgrade from historical instructions.

Full E2E remains open: real Admin UI use, two external registrations, blueprint
creation or authorized reuse, user-only Registry completion, provider-verified
Active, independent Agent 365 and audit landing, Prompt Shields allow/block and
blueprint DLP allow/block. Azure Monitor mirror completeness and any Defender
inventory claims also require fresh exact-window evidence if reported. An accepted
export or a historical portal result does not prove current landing or readiness.

## Historical offline gates

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
Earlier deployments and their evidence remain preserved. An earlier retained
deployment has eleven completed stages, one seed blueprint, and independently
verified database recovery and SQL administrator restoration. Its API startup
ordering correction is accepted in source, but that source cannot be resumed into
the completed source-pinned recovery. Use the authorized fresh target described
at the top of this checkpoint. Do not edit accepted state, replay database jobs,
finalize SQL, or clean up earlier deployments. Exact receipts and current operator
authority remain local; neither transfers through Git or documentation.


## Historical optional protection evidence

In an earlier retained deployment, Prompt Shields reached Azure AI Content Safety successfully. The combined Prompt
Shields plus Purview request failed closed at the Purview dependency.

Directory readback showed the intended Purview Graph app-role assignments, but a
safe in-memory check showed that the managed-identity token did not yet contain
the required Purview roles. No token was printed or persisted. Therefore:

- policy-object readback is configuration evidence only;
- directory role assignment is not token-role evidence;
- that historical build was provisioned with `Purview__Enabled=false`; this is
  not the active deployment's runtime configuration or current-source contract;
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
- Never persist or display raw provider bodies, tokens, credentials, assertions,
  authorization headers, prompts, or responses. Store only bounded sanitized
  evidence in ignored or access-controlled operator records.

## Evidence required after a future deployment

Record environment-specific details outside the public repository, then summarize
only the non-sensitive outcome here:

1. accepted source/configuration/plan fingerprints;
2. immutable deployed image digests and active revisions;
3. exact identity, role, federation, network, and database readbacks;
4. API and Admin UI health;
5. active/scheduled/dead-letter counts for every owned queue;
6. two bounded registrations through `Active` without duplicate Registry mutation,
   using compatible blueprints created or reused as authorized;
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
