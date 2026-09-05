# Implementation status

Last updated: 2026-09-05 (Asia/Seoul).

This is the concise source-of-truth checkpoint for contributors. Public setup starts
at the repository [README](../README.md). Exact deployed development evidence is in
[the deployment status](operations/development-deployment-status.md). A receiving
machine or agent starts unfinished work from the tracked
[agent continuation checkpoint](agent-continuation.md).

## Current product state

The repository implements an N:N Gateway with:

- a role-aware Blazor Admin UI and authenticated ASP.NET Core API;
- one generated external ID and one-time-issued Gateway key per registration;
- typed reusable Agent Identity blueprint selection and compatibility recheck;
- one distinct child Entra Agent ID per registration;
- durable seven-stage provisioning on the dedicated v3 Service Bus queue;
- user-only Agent 365 Registry completion through delegated OBO;
- one-POST Registry recovery based on a creator-bound planned ID;
- final worker verification before `Active`;
- Agent 365 OTLP observability with optional Azure Monitor mirroring;
- registration-scoped data-plane idempotency under SQL application locks;
- optional Prompt Shields and Purview runtime protection;
- a resumable clean-subscription bootstrap with guided and terminal entry points.

Agent 365 Registry remains a beta dependency that Microsoft does not support for
production use. Agent Identity creation uses documented Graph v1.0 surfaces, while
tenant permission availability can still vary. Development can explicitly enable
continuous registration. Staging and production remain closed by default.

## Bootstrap contract

`bootstrap/bootstrap.ps1` is the only supported clean-subscription engine. The root
`gateway` and `gateway.cmd` launchers provide the audience-facing experience.

Bootstrap:

1. validates tools, tenant, subscription, permissions, providers, configuration,
   and the exact configured Azure SQL path in the selected region;
2. creates one resource group and its Azure/Entra resources;
3. builds immutable images from the accepted source tree;
4. initializes only a database with zero user tables;
5. deploys the API, v3 worker, and Admin UI;
6. hardens network access;
7. verifies exact resource, image, identity, and endpoint readbacks.

Bootstrap completion does not require an Agent registration, Prompt Shields, or
Purview. Creating an Active registration is a post-deployment use check. Optional
protection-profile authority never closes ordinary unprotected registration; a
registration that selects a profile is independently validated and fails closed if
that profile is not Ready.

Bootstrap state and evidence live in ignored `.bootstrap/` paths and contain safe
identifiers only. The tool has no destroy mode. If a completed resource group was
deleted, do not replay its preserved state; use a new isolated deployment identity
or an independently reviewed recovery procedure.

The source identifies itself as prerelease `0.1.0-beta.1`. That version is a source
contract, not a deployment claim; a tag can be called live-verified only after its
exact committed source is provisioned and read back.

A stopped step now names its own cause. `Invoke-BootstrapCommand` extracts a bounded
signature from failed provider output — at most eight `code`/`errorCode` values and
four correlation GUIDs — and attaches it to the thrown exception, so the safe failure
event, the Setup timeline, and the persisted checkpoint all carry those identifiers.
The unfiltered provider text never crosses that boundary; it is written to an ignored
`.bootstrap/diagnostics/` file restricted to the current account and referenced only
by path. A failure with no provider signature keeps its curated message unchanged.
Completed-step validators likewise attach only the exact property path and the fact
that it disagreed. Curated validator context is preserved, while expected and actual
resource IDs, endpoints, principal IDs, image digests, and provider text remain
suppressed. The failed checkpoint and terminal error therefore identify the field an
operator must investigate without disclosing either value.

Long provider calls report movement. A registered progress sink receives only values
the bootstrap produced — a command label built from leading lowercase verb tokens, a
phase word, and an elapsed duration — so flags, resource IDs, image references, and
credentials cannot reach it. Completed steps report their duration in text mode.

Prompt Shields free-SKU capacity is checked read-only before the workload deployment.
Azure permits one free Cognitive Services account per account type per subscription,
and ARM rejects a duplicate during template preflight without creating a deployment
record, leaving nothing to read back. The preflight names the conflicting account and
three remediations, and no workload mutation is attempted.

The bootstrap contains bounded compatibility continuations for exact,
already-started deployments affected by reviewed bootstrap defects. Each route
requires the expected prior step state and exact source delta, retains the original
deployment provenance, revalidates the reusable prefix, and binds corrected
execution to a separate fingerprint. Unexpected files, altered historical
evidence, or another source generation are rejected. This is not a general
source-upgrade or resource-adoption mechanism.

Resume preserves the accepted Plan instead of creating or clearing another one.
After obtaining the bootstrap lock, the engine rereads state, routes started `Up`
and `Apply` requests through the dedicated Resume preflight, and independently
revalidates every completed checkpoint. This includes the persistent database Job,
its sole successful execution, the canonical database receipt, schema evidence,
and restoration of the original SQL administrator. Resume authorization is bound
to the accepted Plan, immutable source and configuration, deployment ownership,
completed prefix, current non-completed record, and remaining step list.

The engine also supports a non-mutating, non-interactive checkpoint review. It
returns the preserved accepted-Plan fingerprint and the newly computed Resume
authorization fingerprint, but starts no deployment step. A separately authorized
non-interactive Resume must supply both exact fingerprints; a changed checkpoint is
rejected before mutation. Interactive terminal Resume retains its current-process
confirmation.

The local Setup application now exposes this two-process contract. A stopped or
preserved accepted deployment offers a read-only Resume review that starts one
non-interactive child process without `-Yes`, without any fingerprint, and with
local prerequisite installation explicitly disabled. The sanitizer accepts exactly
one canonical typed review claim bound to its own message; missing, duplicate,
conflicting, malformed, standard-error, or noncanonical claims authorize nothing.
The coordinator holds the accepted-Plan and Resume-authorization fingerprints only
in bounded in-memory state, and a separate user confirmation spends them once in a
new `-Yes` Resume process. Restart, a changed checkpoint, another command, a failed
review, cancellation, or first use invalidates that state. Successful Resume still
requires exactly one nonconflicting Apply-mode endpoint verification result before
Setup reports the Gateway ready. This is source and test evidence; the browser
journey over preserved stopped state has not run, so a restarted Setup process is
not yet claimed as verified end-to-end Resume for an already-started deployment.

Setup validates the typed bootstrap schema and field-specific Azure constraints; it
does not infer whether a deployment name is credential-like from the name's text.
Unknown properties and unsupported advanced configuration remain rejected. Azure
CLI and child-process output are still sanitized before the UI renders them.

Setup discovers the selected subscription's physical Azure locations through the
Azure Resource Manager locations endpoint. Its native dropdown renders the friendly
display name beside the canonical Azure name and persists only the canonical value;
there is no implicit location or free-text region entry. Region visibility is not a
service-availability claim. Doctor, Plan, and the pre-mutation Apply revalidation
fail closed unless the exact configured Azure SQL tier, objective, 2 GiB size, and
LRS storage path are currently reported Available or Default.

On Windows, enabling Purview policy authoring makes Setup load the signed-in
tenant's real sensitive-information-type inventory through Security & Compliance
PowerShell. The user must explicitly load and select one item from a native
dropdown; there is no typed value, static fallback, or default selection in Setup,
Bicep, or runtime options. The configuration stores the type's canonical GUID and
exact current Unicode Name as a pair. Setup verifies the selected Azure tenant and
the signed-in Microsoft Graph user before discovery. Plan validates the persisted
pair without claiming a live tenant-inventory read. Policy authoring and readback
re-enumerate the tenant inventory and reject a missing, duplicate, or renamed
selection. Core bootstrap remains available on macOS and Linux with Purview off;
Microsoft currently documents Security & Compliance PowerShell as unavailable in
PowerShell 7 on those clients. Purview-enabled Up, Apply, Resume, and Verify stop
on a non-Windows workstation before Azure, Graph, or compliance-provider access.

## Provisioning contract

The v3 worker performs blueprint resolution, principal creation, Gateway federation,
child creation, and Agent 365 access assignment. It then waits for the signed-in
Gateway Administrator action. The API owns the Registry boundary and the worker
never calls Registry.

Before Registry creation, the API locks the job, validates the completed prefix,
acquires delegated access, and persists a creator-bound planned Registry ID. It
emits at most one POST. HTTP 201 with a safe returned ID is persisted immediately;
the planned ID is used only when a successful response omits an ID. An unknown POST
outcome permits exact GET only and never another POST.

The Registry adapter has no POST retry loop. Timeout, transport failure,
502/503/504, conflict, and every non-201 2xx response are ambiguous and route to
exact planned-ID GET recovery. Provider bodies remain suppressed.

Final verification re-reads blueprint, principal, federation, child, observability
role, and child-token mapping before setting `Active`.

Active, non-null child Agent Identity object IDs and child client IDs are each
database-unique. The ordered SQL migration rejects pre-existing active duplicates
without rewriting registration data.

## Optional protection contract

Prompt Shields is a pre-model call to Azure AI Content Safety using the API managed
identity. An allow returns a short-lived, single-use receipt bound to the request;
protected interaction ingestion requires and consumes it.
The token provider uses `ManagedIdentityCredential` only; it has no developer,
environment, CLI, workload, or client-secret credential-chain fallback.

Purview runtime uses Graph v1.0 and honors activity-specific inline or offline
processing. Policy authoring has two distinct scopes:

- Know Your Data: fixed tenant-wide enterprise-AI-apps location
  `ee1680d0-702f-4090-b26c-c49091e86531`, `Group`;
- DLP: selected reusable blueprint application ID, `Individual`;
- both: `Application` enforcement plane.

Policy readback is configuration evidence only. Directory app-role assignments do
not prove the current managed-identity token contains those roles. Keep the runtime
adapter disabled until safe token-role and bounded data-plane verification pass.

## Source verification

Every result below was measured on Windows at the current checkpoint unless it
states otherwise. Hosted Windows launcher, browser, and live deployment evidence
remain outstanding.

| Verification project | Passed | Failed | Skipped |
|---|---:|---:|---:|
| Gateway.UnitTests | 661 | 0 | 0 |
| Gateway.AdminUi.Tests | 169 | 0 | 0 |
| Gateway.Setup.Tests | 317 | 0 | 0 |
| Gateway.ObservabilityRuntime.Tests | 189 | 0 | 0 |
| Gateway.ArchitectureTests | 117 | 0 | 0 |
| Gateway.IntegrationTests | 86 | 0 | 0 |
| Gateway.EndToEndTests | 102 | 0 | 0 |
| Gateway.SecurityTests | 126 | 0 | 0 |
| **.NET total** | **1,767** | **0** | **0** |

Run these eight projects directly. `src/A365Gateway.slnx` contains no test project,
so `dotnet test` against that solution reports success without executing a test.

The PowerShell gate spans three Pester directories, not one: `tests/Bootstrap.Tests`
contributes 748 passed with seven non-Windows cases intentionally skipped,
`tests/Gateway.Purview.Tests` contributes 22, and `tests/Operations.Tests`
contributes 32, for 802 passed and none failed out of 809 discovered. Run them
through `tools/Test-BootstrapSource.ps1 -RunPester`, whose `$pesterPaths` array is
the authoritative list, rather than naming directories individually. Adding
`-CompileBicep` validates 18 PowerShell source files and two JSON contracts, then
compiles 27 Bicep templates and three Bicep parameter files. Release build completes
with zero warnings and zero errors.

`dotnet format --verify-no-changes` is not invoked by that script or by any other
local script, so run it by hand over the solution and each test project.
Continuous integration formatted only `src/A365Gateway.slnx`, which by design
contains no test project, so nothing under `tests/` was checked; two whitespace
violations reached `main` through that gap and are now corrected, and the CI job
covers all nine targets. Whitespace, launcher syntax, OpenAPI YAML parsing, local
documentation links, and ignored secret/state path checks pass.

Setup regression coverage now includes Windows-safe Azure CLI/Bicep invocation,
one circuit-scoped wizard under a single interactive router, explicit subscription
selection, and a subscription-backed native region dropdown that stores canonical
Azure names. It also covers the tenant-backed Purview sensitive-information-type
dropdown, exact GUID-plus-Name persistence, selected-account binding, and rejection
of malformed identity or inventory data before policy commands. Plan verifies the
exact selected regional SQL contract, and Setup
binds the reviewed configuration bytes to the Plan process before PowerShell parses
them. A failed Plan returns to reviewed preparation; it cannot invoke a direct retry
with stale configuration. Configuration readers normalize the previously emitted
false-only field while continuing to reject enabled or unknown fields; new writes
omit it. The progress timeline marks its newest stage as working while a run is
live and as stopped once a run ends without succeeding, and it keeps a static ring
under `prefers-reduced-motion` so the cue survives the animation reset.

Recovery coverage includes exact source-continuation provenance, rejection of
unexpected changed paths and a third generation, tamper detection for preserved
history and completed-prefix evidence, and the deterministic governance-NSG
What-If extension on later Resume. These cases are included in the consolidated
PowerShell source gate above.

The launcher, standalone source-compiler, Azure CLI boundary, Bicep prerequisite,
and Entra credential and orphan-cleanup regressions that earlier revisions listed as
a separate table are files inside `tests/Bootstrap.Tests` and are already counted in
its 748. Do not restate a subset as though it were an independent gate.

The explicit Windows Bicep compilation lane has run for this source generation and
passed. Closing that lane required one contributor-tool correction.
`tools/Test-BootstrapSource.ps1`
resolved the Azure CLI with an unbounded `Get-Command az -CommandType Application`.
The Azure CLI MSI installs both `az.cmd` and an extensionless shim in the same
directory, so that call returned two matches whose `Source` cast to a single
space-joined path, and the lane then failed closed on an unusable boundary. The
resolver now binds exactly one command source and deterministically promotes an
extensionless shim to its sibling Windows launcher before the existing bundled-Python
mapping. Anything else still fails closed. The shipped bootstrap engine resolves the
Azure CLI through a different, single-match call and was not affected.

The first hosted beta-candidate run exposed the same multi-match shape for `chmod`
on Ubuntu: both `/bin/chmod` and `/usr/bin/chmod` were returned, and PowerShell
collapsed their `Source` values into one invalid command path. Restricted diagnostic
files and temporary ARM parameter files now use one shared deterministic
application-command resolver. The focused Linux-shaped regression and the complete
Windows Pester gate pass; the corrected commit still requires its own hosted CI run.

The secure credential path uses one ARM child-resource
deployment against the exact configured subscription, emits no secret value, and
requires only value-free management-plane metadata readback. The obsolete Key
Vault data-plane credential helpers and their direct tests were removed.

The current source is ahead of the deployed build, so the results above are source
evidence and not a release claim. Earlier revisions of this file were written before
any live deployment existed; that is no longer the situation. A gateway has been
provisioned and verified on Azure, and
[the deployment status](operations/development-deployment-status.md) is the
authoritative record of exactly which revision that evidence belongs to. Anything
committed after that checkpoint is undeployed until the next clean provision records
its own readbacks. A final hash-scoped security rereview of the backend Resume and
private-vault boundaries passed with no remaining blocker; those cases are included
in the .NET total above.

## Known external limitations

- Preview Microsoft contracts can change or vary by tenant.
- Immediate Registry exact GET may not expose a just-created record.
- Managed-identity role changes can take time to appear in tokens.
- Purview FeatureConfiguration cmdlets are Public Preview and are not available in
  every organization.
- Security & Compliance PowerShell is unavailable in PowerShell 7 on macOS and
  Linux, so optional bootstrap SIT inventory and policy authoring require Windows.
- `downloadText` may be offline; do not claim response-side inline enforcement.
- Local tests and policy readback are not live deployment or provider-verdict proof.

## Safe resume point

The offline gate is green for this source generation, and the Setup two-step Resume
review and confirmation integration is implemented, tested, and independently
rereviewed. A source revision is not deployed evidence, and the current source is
ahead of the deployed build.

The remaining goal is live: a blueprint-scoped Purview DLP allow and block pair
observed on a deployed build. It cannot be reached by changing the existing
deployment, because bootstrap refuses to mix source generations inside one
deployment state; the supported path is a fresh provision under a new unused
deployment identity with Purview enabled from the start. The
[Purview runbook](operations/purview-setup-runbook.md) states that as its case B,
and `.\gateway.cmd plan` — `./gateway plan` on macOS — is the discriminator. That
run authors tenant policy over an interactive sign-in, so it is Windows-only and
cannot run unattended.

For the `0.1.0-beta.1` candidate, the authorized live exercise is broader: create
two registrations on one newly created blueprint and two on one existing blueprint,
require all four to reach provider-verified `Active`, then validate Agent 365
observability, Prompt Shields allow/block behavior, and the Purview DLP allow/block
pair with approved synthetic input. The exact new resource group must be named and
authorized before bootstrap starts.

Two platform checks are still open and neither blocks that goal: the macOS root
`gateway` launcher on the core path with Purview disabled, and fixture-backed local
browser inspection of the Setup Resume journey at desktop and narrow widths over
representative preserved stopped state. The hosted Windows launcher check named in
earlier revisions is closed; operator-run Windows bootstraps have provisioned
complete gateways through `gateway.cmd`.

The validator-diagnostics source task in the
[agent continuation checkpoint](agent-continuation.md) is complete and independently
rereviewed. No further source task is selected; the remaining delivery goal is the
operator-gated live Purview evidence above.

For any authorized Azure, Entra, SQL, Graph, Purview, or deployment action, first
read [the deployment status](operations/development-deployment-status.md) and the
relevant runbook. Preserve ignored bootstrap state and never read or print
`.secret`/`.secrets` values. Live authorization does not travel with Git: a grant
recorded in chat history, in a previous session, or for a previous deployment is not
a grant for the next one, and creating or retiring a resource group each require a
fresh explicit authorization naming that specific group.
