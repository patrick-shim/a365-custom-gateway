# Implementation status

Last updated: 2026-09-01 (Asia/Seoul).

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

Agent 365 Registry and several Agent Identity surfaces remain preview dependencies.
Development can explicitly enable continuous registration. Staging and production
remain closed by default.

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

Final verification re-reads blueprint, principal, federation, child, observability
role, and child-token mapping before setting `Active`.

## Optional protection contract

Prompt Shields is a pre-model call to Azure AI Content Safety using the API managed
identity. An allow returns a short-lived, single-use receipt bound to the request;
protected interaction ingestion requires and consumes it.

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

The consolidated source gate completed on 2026-09-01. Every result below was
measured on Windows unless it states otherwise. Hosted Windows launcher, browser,
and live deployment evidence remain outstanding.

| Verification project | Passed | Failed | Skipped |
|---|---:|---:|---:|
| Gateway.UnitTests | 640 | 0 | 0 |
| Gateway.AdminUi.Tests | 157 | 0 | 0 |
| Gateway.Setup.Tests | 298 | 0 | 0 |
| Gateway.ObservabilityRuntime.Tests | 158 | 0 | 0 |
| Gateway.ArchitectureTests | 115 | 0 | 0 |
| Gateway.IntegrationTests | 85 | 0 | 0 |
| Gateway.EndToEndTests | 102 | 0 | 0 |
| Gateway.SecurityTests | 126 | 0 | 0 |
| **.NET total** | **1,681** | **0** | **0** |

Run these eight projects directly. `src/A365Gateway.slnx` contains no test project,
so `dotnet test` against that solution reports success without executing a test.

The PowerShell source gate discovered 748 tests on Windows: 741 passed, none failed,
and seven non-Windows cases were intentionally skipped. It validated 18 PowerShell
source files and two JSON contracts, then compiled 27 Bicep templates and three
Bicep parameter files. Release build completed with zero warnings and zero errors;
`dotnet format --verify-no-changes`, whitespace, launcher syntax, OpenAPI YAML
parsing, local documentation links, and ignored secret/state path checks also
passed.

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
omit it.

Recovery coverage includes exact source-continuation provenance, rejection of
unexpected changed paths and a third generation, tamper detection for preserved
history and completed-prefix evidence, and the deterministic governance-NSG
What-If extension on later Resume. These cases are included in the consolidated
PowerShell source gate above.

The current pause checkpoint has the following narrower offline evidence, measured
on Windows unless a row states otherwise:

| Current correction gate | Passed | Failed | Skipped |
|---|---:|---:|---:|
| Complete .NET test set | 1,681 | 0 | 0 |
| Complete bootstrap Pester set on Windows | 741 | 0 | 7 |
| Launcher regressions executed on Windows | 11 | 0 | 6 |
| Standalone source-compiler regressions | 10 | 0 | 0 |
| Windows Azure CLI boundary regressions | 8 | 0 | 0 |
| Windows Bicep prerequisite regressions | 9 | 0 | 0 |
| Entra credential and orphan-cleanup regressions | 33 | 0 | 0 |

The Release solution build completed with zero warnings and zero errors. The source
compiler parsed 18 PowerShell files and two JSON contracts, then locally compiled
27 Bicep templates and three parameter files. The explicit Windows Bicep compilation
lane has now run for this source generation and passed.

Closing that lane required one contributor-tool correction. `tools/Test-BootstrapSource.ps1`
resolved the Azure CLI with an unbounded `Get-Command az -CommandType Application`.
The Azure CLI MSI installs both `az.cmd` and an extensionless shim in the same
directory, so that call returned two matches whose `Source` cast to a single
space-joined path, and the lane then failed closed on an unusable boundary. The
resolver now binds exactly one command source and deterministically promotes an
extensionless shim to its sibling Windows launcher before the existing bundled-Python
mapping. Anything else still fails closed. The shipped bootstrap engine resolves the
Azure CLI through a different, single-match call and was not affected.

The secure credential path uses one ARM child-resource
deployment against the exact configured subscription, emits no secret value, and
requires only value-free management-plane metadata readback. The obsolete Key
Vault data-plane credential helpers and their direct tests were removed.

The source in this checkpoint has not been deployed or live-tested. The local
results above are not a release claim and do not replace the required hosted
Windows, browser, and authorized live-deployment gates. A final hash-scoped
security rereview of the backend Resume and private-vault boundaries passed 356 of
356 focused tests with no remaining blocker.

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

The Setup two-step Resume review and confirmation integration described above is
implemented, tested, and independently rereviewed, and the Windows Bicep compilation
lane has passed. Continue with the platform and browser checks named in the
[agent continuation checkpoint](agent-continuation.md): a hosted Windows run of the
root `gateway.cmd` launcher with real prerequisite detection and repair, the macOS
root `gateway` launcher and core Setup path with Purview disabled, and fixture-backed
local browser inspection of the Setup Resume journey at desktop and narrow widths
over representative preserved stopped state. Do not start a live provider action
while any of those checks is unresolved.

For any later authorized Azure, Entra, SQL, Graph, Purview, or deployment action,
first read the deployment status and relevant runbook. Preserve ignored bootstrap
state and never read or print `.secret`/`.secrets` values. The next clean deployment
must use a new unused deployment identity and follow the public README only after
the Resume-enabled Setup journey is complete. No agent, assistant, or contributor
may resume live work until the user returns and explicitly requests it.
