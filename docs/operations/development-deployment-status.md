# Development deployment status

Last updated: 2026-09-07 (Asia/Seoul).

This checkpoint separates deployed evidence from source claims. It intentionally
contains no subscription, tenant, resource-group, application, principal,
registration, image-digest, correlation, credential, token, prompt, response, or
provider-body value. Environment-specific evidence belongs in ignored
`.bootstrap/` output or an access-controlled operator evidence store.

For unfinished source work after a fetch, pull, or fresh clone, begin with the
tracked [agent continuation checkpoint](../agent-continuation.md). Git alone does
not transfer the ignored state required to Resume an existing deployment.

## Current operator direction and evidence boundary

Apply the [end-to-end execution contract](../agent-guides/end-to-end-execution.md).
The latest instruction authorizes automated clean teardown, Windows Setup UI
deployment, full live multi-agent/blueprint observability, SIT DLP and Prompt
Shields testing with safe screenshots, and a repeated scratch run. It supersedes
the earlier recovery-first/paused direction. Credentials were supplied and existing
authenticated subscription/group inventory succeeded without reading their values.
The operator subsequently selected one subscription under the full teardown
directive. Cleanup is independently verified within that subscription: zero groups
and active ARM resources, with all original groups absent. Eight parent deletions
removed four managed groups through Azure; no platform locks or deny assignments
were bypassed, and no soft-deleted assets or tenant identities were purged.
All other subscriptions and prior local evidence remain untouched.
The actual Windows Setup UI Plan succeeded for a fresh Full evaluation identity
on the corrected, independently re-reviewed executor integration source. Apply was
started once through the UI's Plan-bound confirmation. It completed fourteen stages
and stopped at runtime deployment before executor mutation intent. Safe read-only
reproduction confirmed an ARM GET incorrectly routed through the Graph-only
dispatcher, not an authorization failure. SQL completed once, Purview prerequisites
completed, and the initial API activation failure recovered without intervention.
The failed state/config/evidence are preserved and attempt1 teardown is verified
with zero groups/active ARM resources. The routing correction passed independent
review and current offline gates. Fresh UI attempt2 Plan succeeded; Apply completed
fourteen stages before its sixty-minute validity window expired. The actual UI
read-only Resume review validated those checkpoints, including the one database
execution and administrator restoration, and a fresh remaining-step confirmation
started supported same-source Resume once. No guard, clock, source or config was
changed and no completed action was replayed. It created and verified executor
identity/image and disabled host/publisher resources, then stopped before publisher
execution on null-secret and case-normalized ARM-ID validation. The corrected
publisher source was used for one supported same-source Resume; it revalidated
stages 1-14, provisioned the executor resources, and then failed at stage 15.
A subsequent sanitized diagnosis found the executor ARM deployments and one
prior succeeded publisher execution, but no safe dependency error detail.
No deployment completion or live acceptance is
yet proven; no completed SQL/certificate action is replayed. Exact inventory/authority references stay in the local execution
context; use [agent continuation](../agent-continuation.md) for the current next action.

Protocol-only checks passed: 70 cross-tool Pester tests, isolated ledger self-tests
and independent review with no high-confidence findings. No deployment or live
acceptance claim is made by these checks.

## Prior stopped deployment evidence

The operator stopped work and handed the task to another model. The fully running
Gateway has **not** been delivered. Do not restart deployment automatically from
this checkpoint; continue when the operator resumes. Exact target, original
authorization, configuration and recovery evidence remain in ignored local operator
records and do not transfer through Git.

Two bootstrap defects that blocked the Purview prerequisite stage were found,
corrected against current Microsoft documentation, and pushed to `main`.

The first defect built the Microsoft Entra key-credential window from the requested
generation values instead of the issued certificate. That produced two simultaneous
violations: a sub-second `endDateTime` outliving the certificate's whole-second
`NotAfter`, and a window of one year plus five minutes exceeding the documented
one-year maximum. Entra rejected the whole application update as a validation
failure, which is the previously undiagnosed publication error. The window is now
derived from the issued certificate, clamped inside its validity and under one
year, and formatted to whole UTC seconds.

The second defect asked Microsoft Graph to filter the `domains` collection.
Microsoft documents `$filter` as unsupported there, and the service answers HTTP
400 `Request_UnsupportedQuery`. The initial verified domain is now selected from
the returned collection. The uniqueness, verification and domain-shape guards are
unchanged.

Both corrections are proven by exact live provider readback, not by local state or
configuration. The automation application on the active target now carries exactly
one key credential with a whole-second window inside the certificate; this is the
first successful publication of that credential on any target. The corrected domain
lookup returned the tenant initial verified domain in a read-only call against the
same tenant.

A clean deployment of the current source was separately authorized on a new
development target. It reached thirteen of nineteen stages complete with the
Purview prerequisite stage failed. Its certificate is **not** partial: publication
succeeded and only the subsequent domain readback failed, which the second
correction addresses. The earlier retained target that holds the partial
certificate is untouched. Its certificate, both grants, accepted snapshot,
completed stages and operation record were not replayed, rotated, cleared or
rerun through the identity Ensure function. Preserve it exactly as recorded.

Both corrections landed after that deployment's plan was accepted, so the current
source fingerprint no longer matches its accepted-source snapshot. This is the
active blocker and it is unresolved. Resume stops at its accepted-authorization
preflight because current source differs from the accepted source without a
completed automatic database recovery. Plan refuses because the deployment has
already started. Resume also executes bootstrap modules from the accepted-source
snapshot rather than the working tree, so even a passing Resume would run the
uncorrected source. No supported operator path out of this state had been
established when work stopped.

Do not force progress. Do not edit or delete accepted state, remove `.bootstrap`,
weaken the source-binding guard, or replay a completed recovery in order to adopt
new source. If no supported command accepts a corrected source generation on a
started deployment, that is a reviewable source gap to report to the operator with
its trade-offs, not a guard to bypass.

No registration, delegated Registry completion, worker-verified `Active`,
independent Agent 365 landing, Prompt Shields allow/block or DLP allow/block has
passed for the active target. Windows executor deployment integration, dedicated
identity creation, package rebuild and publication, upgrade receipt,
fresh-bootstrap wiring and actual Windows/provider proof also remain unfinished;
the old package is stale and must be rebuilt against final source. Canonical `main`
is the sole checkout, with no branch or worktree created. Credentials and runtime
evidence remain outside Git.

## Validation for the two corrections

These are source gates. They are not deployment evidence or live-readiness proof.

| Gate | Result |
|---|---|
| Focused Purview certificate and identity tests | 45 passed, 0 failed |
| Focused credential-window and domain-lookup tests | 50 passed, 0 failed |
| Bootstrap, Operations and Purview Pester | 964 passed, 0 failed, 7 skipped |
| Hosted CI for the credential-window commit | Passed |
| Hosted CI for the domain-lookup commit | Passed |

Each correction carries focused regression tests that fail against the previous
behaviour. The final recovery selectors passed 50/50, the bootstrap source gate
passed, and the source plus Windows/POSIX launcher tests passed 21 with six
existing skips. Release build, the eight .NET test projects, Bicep compilation,
the nine format targets and a clean export were not rerun. These results remain
offline source evidence only; rerun the broader release gates before any release
claim.

## Earlier validation for the promoted Windows executor source

The combined handoff source passed Release with zero warnings and errors, all 2123
.NET tests across eight projects, 31 package/source-binding Pester tests, source
structure checks, document/link/private-path checks and independent handoff review.
The earlier architecture failure was a stale expectation of the removed local
provider; its assertion now expects the reviewed remote provider and all affected
tests pass. Hosted CI later passed for the promoted-source commit. Full
bootstrap/export gates for that combined source remain pending. No live gate was
closed by that handoff.

## Historical preserved deployment and startup correction

The following retained-target evidence predates the active clean attempt.
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

The active deployment is the clean attempt described at the top of this checkpoint.
No previous deployment's telemetry, registration or protection result closes its
remaining gates. Detailed historical telemetry and troubleshooting chronology
remain in Git history.

Bootstrap prepares shared capabilities only. It never selects a sensitive
information type or authors Know Your Data or DLP policy. Gateway Settings owns
those operations and requires exact provider verification of its automation
authority. Creating or reusing a compatible blueprint does not bypass DLP profile
readiness. Both compliance providers require the reviewed Windows execution path;
the Linux worker's module installation proves neither connection nor authoring.

The accepted bootstrap source and completed stage evidence remain immutable.
Ordinary Resume cannot silently adopt changed source, and that is the active
blocker: the two corrections landed after the active plan was accepted, so Resume
refuses the changed source and Plan refuses a started deployment. Establish a
supported path or report the gap before changing anything. No new resource group,
database initialization or replacement identity is authorized by this handoff.

The retained earlier target stopped inside the
[narrow prerequisite recovery](purview-prerequisite-recovery.md) with a partial
certificate. That command cannot repair that state, and the operator deferred the
repair until the active deployment runs. The publication failure itself is now
explained by the corrected credential window, so the repair no longer needs
diagnosis; it needs an exact reviewed write that publishes the preserved Key Vault
certificate without rotating, recreating, clearing or replaying anything.

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
