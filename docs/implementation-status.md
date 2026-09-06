# Implementation status

Last updated: 2026-09-06 (Asia/Seoul).

This is the concise source-of-truth checkpoint for contributors. Public setup starts
at the repository [README](../README.md). Exact deployed development evidence is in
[the deployment status](operations/development-deployment-status.md). A receiving
machine or agent starts unfinished work from the tracked
[agent continuation checkpoint](agent-continuation.md).

## Current live stop: inert API startup

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
Hosted CI must also be green for the containing commit before deployment.

Independent review confirmed that no existing supported command accepts this new
source generation after completed source-pinned database recovery. Preserve that
deployment, its state, jobs, identities, accepted snapshots, and credentials. Do not
replay recovery or bypass the source and readiness guards. A new isolated deployment
needs its own exact-target authority; no additional target has been authorized.

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

## Protection Settings implementation — beta.2 offline acceptance passed

The `0.1.0-beta.2` protection-governance source is implemented and accepted offline.
Bootstrap installs shared capabilities; role-aware Gateway Settings owns tenant
connection, SIT selection, independent KYD Group and blueprint Individual DLP,
readiness, defaults, and per-registration controls. Full evaluation is the Quick
development default with explicit acknowledgements; Core Gateway omits optional
dependencies, and Custom selects them independently. Staging and production keep
Registry beta closed.

Registration retains seven stages on `gateway-provisioning-v3`. Protection
administration uses only `gateway-protection-admin-v1`. Registry remains user-only
delegated OBO with at most one POST and exact-ID recovery; Active still requires
final provider verification. Capability installation never substitutes for policy,
propagation, token-role, or allow/block evidence.

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


The original deployment remains preserved at failed inert verification. The
separately authorized replacement passed that check and completed ten stages,
including one seed blueprint, before its single database job failed at the exact
post-EnsureCreated relational schema comparison. SQL administrator restoration was
independently verified. Admin UI, registration, and protection E2E remain unproved.

Complete the inert API startup correction before proposing a new deployment. Do not edit accepted state, replay the failed job,
finalize SQL, or clean up either deployment. Exact receipts and current operator
authority remain local; neither transfers through Git or documentation.


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

The source identifies itself as prerelease `0.1.0-beta.2`. That version is a source
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

Setup no longer loads or selects a SIT and bootstrap no longer authors Purview
policy. When Purview prerequisites are selected, bootstrap prepares and exactly
reads back the automation app/service principal, reviewed Graph and compliance
roles, CSP-compatible certificate and private Key Vault metadata, runtime wiring,
and `gateway-protection-admin-v1` queue with scoped sender/receiver RBAC and worker
settings. Core and Purview-off Custom omit those dependencies.

After deployment, a signed-in Administrator uses Settings. The immutable Admin UI
image publishes the canonical Windows companion at
`/downloads/Connect-PurviewTenant.ps1`; the browser never auto-runs it. The companion
opens the official interactive Security & Compliance session, proves the exact
tenant and user, inventories bounded SIT GUID/name/publisher facts, and emits one
prefixed typed result. The API independently validates and verifies that evidence.
Security & Compliance PowerShell remains unavailable in PowerShell 7 on macOS and
Linux, so the companion handoff is Windows-only while bootstrap remains
cross-platform.

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

Protection administration is API-owned and `Gateway.Administrator`-only for
mutation. A one-time review is separately confirmed before mutation. Matching
`If-Match`/row version and canonical idempotency are required; per-user and per-IP
rate limits apply. Operators can read bounded governance state, while Auditor and
SupportReader views are restricted.

The dedicated version-1 workflow persists eight stages: validate reviewed intent,
discover provider state, apply only the reviewed mutation, record exact readback,
verify propagation, attest token roles, validate runtime verdict, and complete.
Registration still uses only its seven v3 stages.

## Source verification

The final beta.2 counts and fresh review result above supersede earlier concurrent
and pre-fix evidence. Both the working candidate and a clean export passed the
Release build, all eight test projects with nonzero execution, and the canonical
PowerShell/Pester/Bicep gate. All nine format targets passed on the final source.

OpenAPI YAML and internal references, Markdown links/anchors/fences, Claude
frontmatter, Codex TOML, skill YAML, cross-tool behavioral parity, ignored private
paths, whitespace, launcher smoke, and the full local delivery-ledger audit passed.
The export included every intended tracked and new file and matched the source
fingerprint independently verified by the final security/UI reviewer.

Setup coverage includes capability presets and acknowledgements, reviewed config
bytes bound to Plan, stopped-state Resume, exact reusable-prefix validation, and
Windows-safe native command discovery. Registration tests preserve the seven-stage
queue, delegated Registry boundary, one-POST recovery, and final verification.
Protection tests cover capability/runtime drift, current tenant/SIT readiness,
provider-ID-bound updates, cancellation cleanup, and truthful UI effective state.

Run tests per project: the shipping solution contains no tests. Use the canonical
`tools/Test-BootstrapSource.ps1 -RunPester -CompileBicep` command and explicitly
verify formatting over the solution plus each test project. Hosted CI must be
checked against the exact commit. These are source results; older live evidence
belongs only to the revision recorded in the deployment checkpoint.

## Known external limitations

- Preview Microsoft contracts can change or vary by tenant.
- Immediate Registry exact GET may not expose a just-created record.
- Managed-identity role changes can take time to appear in tokens.
- Purview FeatureConfiguration cmdlets are Public Preview and are not available in
  every organization.
- Security & Compliance PowerShell is unavailable in PowerShell 7 on macOS and
  Linux, so the Settings-owned interactive SIT inventory and policy
  authority bridge remains Windows-only where those cmdlets are required.
- `downloadText` may be offline; do not claim response-side inline enforcement.
- Local tests and policy readback are not live deployment or provider-verdict proof.

## Safe resume point

Beta.2 integrated offline acceptance, independent security/UI source review, and
clean export are complete, and all five hosted jobs passed for the Boolean
correction. A receiving checkout verifies its actual HEAD and
associated CI before acting; see the bounded
[continuation checkpoint](agent-continuation.md).

The original deployment remains preserved at failed inert verification. The
separately authorized replacement passed that check and completed ten stages,
including one seed blueprint, before its single database job failed at the exact
post-EnsureCreated relational schema comparison. SQL administrator restoration was
independently verified. Admin UI, registration, and protection E2E remain unproved.

Complete the inert API startup correction before proposing a new deployment. Do not edit accepted state, replay the failed job,
finalize SQL, or clean up either deployment. Exact receipts and current operator
authority remain local; neither transfers through Git or documentation.

The future authorized E2E uses a clean bootstrap, two new blueprints and one external
registration per blueprint. Both must reach provider-verified Active and independently
prove Agent 365 observability, Prompt Shields allow/block, and Purview DLP allow/block.

The previously identified macOS interactive core-launcher check and fixture-backed
Setup Resume browser journey remain separate platform checks. The explicit browser
waiver above applies to the changed protection UI acceptance; it is not live or
Setup browser evidence.

Before any separately authorized live action, read the
[deployment status](operations/development-deployment-status.md) and relevant runbook.
Preserve ignored bootstrap state and never read or expose `.secret`/`.secrets` values.
