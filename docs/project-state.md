# Project continuation state

Updated: 2026-09-25 KST.

Read [the milestone checklist](../MILESTONES.md) for completion. This document
records operational context and the next action, not a second acceptance ledger.

## Reboot checkpoint: paused at the user's request

Saved 2026-09-25 03:55 KST (2026-09-24 18:55 UTC). The user requested a laptop
reboot and will resume afterward. Do not start another build or deployment until
resumption. All authored changes and existing operational evidence are retained
locally; no commit or push was requested or performed.

The latest exact-source review is **approved**, and canonical Build Plan admission
also passed. The subsequent Build, run under the required PowerShell 7.6.5/X64,
failed its own fresh read-only baseline verification at 18:53:47 UTC. The bounded
error is `UpgradeBaseline: current read-only verifier failed; provider output
suppressed. Original history was not rewritten.` No provider classification or
source frame was returned, so the cause is not established. Do not label this
another B1 rejection, infer a transient failure, or bypass the guard.

The exact execution directory exists but has **zero entries**. The failure is
before cloud-lease acquisition and the first image/package action in the canonical
pipeline. No new artifact bundle, ACR build dispatch or application deployment
occurred. Both owned Plan/Build processes have exited. The browser opened for
read-only sign-in/navigation was closed; no connection/policy action or draft
change was submitted. The hosted application remains the earlier `dea` release.
M5.1 stays checked for its tested source; reopened M4 tasks and M5.2-M5.6 remain
unchecked. M6 has not started.

Checkpoint integrity was rechecked: immutable candidate, canonical Plan and exact
source-review bindings pass, and the local execution lock can be acquired and
released. Documentation validation passes all 37 validator self-tests and the
current structural run (963 stable authored inputs, 27 Markdown documents,
336 local links, 15 anchors, 427 OpenAPI references and 48 operations).
Whitespace checks pass. These are persistence/structural checks, not release
or provider acceptance.

### Exact retained restart inputs

- Candidate:
  `sha256:7e18c7d4e4dcb44b6ecd7557438b9ace8b92bd1ce25db4ea4a76c50b706465ed`.
  Receipt:
  `.maintenance/candidates/7e18c7d4e4dcb44b6ecd7557438b9ace8b92bd1ce25db4ea4a76c50b706465ed/provenance.json`.
- Content/source:
  `sha256:f1da9bddc178ef6794b0801d0351952ec35af4fdf48cdd96a2e6e06c5bca40f5`.
  Artifact source:
  `sha256:80356dea08e3e6d902a5a54ae5648226851357354ad3f220fcd65abf12ea7965`.
- Prepare:
  `.maintenance/validation/043eb300977143ef82a7be464a206218.json`.
  This pins the 98-file compiled toolchain and unchanged EF model.
- Request:
  `.bootstrap/novice-protection-20260924/source-only-full-b1-20260925.json`.
  It explicitly accepts the existing one-worker B1 selection, not resizing.
- Independent source review:
  `.bootstrap/novice-protection-20260924/source-review-7e18c7d4e4dc.json`.
  Genuine GPT-6 Astra reviewer `72a6b4f2-2059-49ff-9f2e-35084cc9f87e`,
  turn 5, approved the exact bindings/six-file delta and passed 65 focused cases.
  This is source approval, not artifact/deployment/provider approval.
- Build Plan:
  `.maintenance/upgrades/novice-b1-20260925/f6a307b944775ccada64ed647c35d26cd960b43ac78f18be62a55a9bd30476ad/plan.json`.
  Fingerprint:
  `sha256:f6a307b944775ccada64ed647c35d26cd960b43ac78f18be62a55a9bd30476ad`.
  `buildSupported=true`; `executionSupported=false`. Its own baseline passed
  at 18:43:09 UTC with result `67de965b...`; this does not replace Build's check.
- Logs in `.bootstrap/novice-protection-20260924`:
  `b1-reviewed-build-plan-7e18c7d4e4dc.log`,
  `b1-canonical-build-7e18c7d4e4dc.log`,
  `b1-clean-source-verification.log`, and `b1-prepare-7e18c7d4e4dc.log`.
- Required launcher for the **entire** canonical Build:
  `.bootstrap/release-inputs/powershell-7.6.5-win-x64-5eae2a2b6ff74a3cb31644b4268a6562/runtime/pwsh.exe`.
  Running only a prerequisite check in this shell and Build in 7.6.6 is invalid.
- Original state:
  `.bootstrap/state/6f6ae863-dcb7-456f-a7f0-d6f9887cfb76-rg-a365q5b-dev-20260922-dev.json`,
  SHA-256 `c9cbda3a3d358d4b8ebef7d0a841812825ac8430bf103667969d1f0183ded870`.
  Original configuration: `.bootstrap/m5-corrected-20260922/config.json`,
  SHA-256 `1cd1cb06a7af7aa9247394eac2d06ac20ba4f8c24e7342e4d625968b92c74fc7`.
  Both were rechecked unchanged at this pause.

### First action after resumption

Recheck the retained bindings, original hashes and pinned Azure session. Diagnose
the actual same-launcher read-only baseline failure before continuing the exact
Build Plan. Plan admission ran in the ordinary shell; Build and its verifier ran
under 7.6.5/X64. That difference is a diagnostic lead, not a proven cause. Preserve
failed attempts and bounded diagnostics; do not replay accepted provider work or
reuse a historical pass as admission.

If source changes are necessary, requalify/freeze/review the replacement rather
than relabeling `7e18c7d4...`. Otherwise continue the exact approved Plan through
canonical Build, qualify all five immutable images and the actual Windows ZIP,
create a separate artifact-bound Plan, finish the current Azure validation
workflow, and only then deploy/Verify and browser-check the hosted novice journey.
Validation currently stops at `AddValidationSteps`; the deployment plan is
`Ready for Validation`, not `Validated`. The existing maintenance endpoint helper
has local controls but no live run. Retain the three uncertain policy operations
below. No B2 exception, receipt rewrite or new M6 deployment is authorized by this
restart.

## Current follow-up: novice protection workflow

The user authorized a holistic improvement of the connection/shared-policy
journey. M4.1, M4.3, M4.4, M4.7 and M4.8 are reopened in the milestone record.
The full-stack candidate also reopens dependent M5.2-M5.6 delivery/closure gates;
the 2026-09-22 qualification remains evidence only for its original release.
M5.1 now passes for the B1 hosting contract/default in candidate `7e18c7d4...`.
Its new clean copy passed all 1,478 .NET cases, 538 StrictMode Pester cases,
the three portable gates and source-stability checks. All 723 packaged inputs
match the passing copy, and canonical Prepare confirms the unchanged model.
The historical `d9c98751...` approval does not approve these replacement bytes;
the separate exact-source `7e18c7d4...` review is approved. Downstream delivery
gates remain required.
The preceding metadata-version candidate completed Build and local exact-artifact
qualification, but its read-only preflight exposed this separate defect before
application mutation. Corrected clean-source qualification passes; the
preceding candidate's approvals and artifacts cannot approve replacement bytes.
The implementation keeps Blazor; the observed issues concern workflow, state
presentation and provider reads, not a demonstrated framework limitation.

**Current direction, 2026-09-25 KST:** the user explicitly approved B1, conditional
on quota, and instructed continued delivery. Fresh readback confirms the existing
one-worker Windows B1 plan is Ready/Succeeded and selectable. The selected
maintenance path needs no additional App Service workers. B1 supports the existing
private networking. The explicit source-bound acceptance of this already-allocated
SKU is implemented and source-qualified while keeping historical B2 receipts unchanged;
do not require a corporate B2 exception or change governance. M5.1 is verified;
the hosted site still runs `dea`. The actual isolated canonical baseline passed
at 2026-09-24 17:49:30 UTC with explicit B1 echo and result `f30495f3...`.
Genuine GPT-6 Astra follow-up now approves exact `7e18c7d4...` source with no
significant findings after independent binding/delta/consumer checks and 65
passing StrictMode regressions. New Build Plan `f6a307b9...` is admitted, but
Build's subsequent fresh baseline failed before any artifact action, as detailed
in the reboot checkpoint. Neither source approval nor Plan admission deployed
the candidate.

Read-only diagnosis of the three accepted policy operations is retained under
`.bootstrap/novice-protection-20260924`. Two attempts crossed their inventory
expiry during slow provider work. An earlier failure's timing is consistent with
the native timeout, but its original native failure classification is unavailable.
The missing policy/rule provider IDs do not establish that Microsoft objects are
absent. Do not replay those operations or repeat the earlier tenant reference
registration.

Current source removes a reproduced duplicate catalog read, imports only the
commands needed by each native operation, checks freshness before writes, and
preserves bounded timeout/expiry read failures. It also permits a newly reviewed
and confirmed read-only reconciliation to bind unchanged saved selections to
the current connection inventory. Identity/settings/agent choices are preserved;
earlier runtime proof is cleared. Old reviews are not rebound. Targeted owned-SQL
and provider regressions passed; their verification basis is on M4.4.

The navigation/count/recovery and scoped activity changes are integrated,
including visible header/dialog feedback. Completed earlier-task history is
collapsed and labeled; pending/failed/unreadable work remains visible. Refresh,
blueprint changes and Cancel edit wait for the editor's prerequisite read without
resetting its draft or feeding its busy state back into itself. The scoped test
now disposes the actual component tree and verifies cancellation before releasing
a late response; no production disposal change was needed.

The final fresh actual-component build and installed Chrome passed 146 M4 and
180 M3 checks, with no nonlocal requests or unexpected browser errors. This
includes the final parent/child gating, defaults, edited reselection, responsive
layout and reduced-motion behavior. The owned HTTPS fixture was gracefully
stopped and its temporary certificate file removed. All identity/API data are
synthetic; the separately tested design prototype is not provider evidence.

The most recent complete clean authored-source baseline, before the metadata
fix below, passed: 960 copied inputs, 73 parsed PowerShell sources,
1,454 .NET tests (398 UI and 138 real owned-SQL cases), 447 StrictMode Pester
tests across 13 files, all three portable gates and the unchanged-source guard.
No tests were skipped or left unrun. Earlier attempts are superseded, not combined
into that result. Three scalar Pester display names needed `<_>` because the
canonical runner uses StrictMode; assertions were not weakened.
Current structural documentation/configuration validation also passes: 332 local
Markdown links, 48 OpenAPI operations, all 37 validator self-tests and
source/role/schema agreement, with
explicit provider/runtime exclusions. The ordinary independent integration review
completed with no significant issues after bounded source/diff/test/contract
inspection and PowerShell parsing. It did not rerun the suites, review maintenance
or approve deployment. The separate genuine GPT-6 Astra review approved the earlier
`f481e7f7...` frozen candidate for maintenance source use, with no significant findings.
Invocation and returned harness metadata identify the model; this is not a
reviewer self-attestation. The reviewer independently recomputed the candidate,
723-input content source and 45-input caller-verifier bindings, checked the
original archive/provenance and performed bounded parse/synthetic probes.
The review did not rerun supplied suites or perform live diagnosis or deployment.
A bounded genuine review of replacement `d7613ff7...` is also approved for source
use with no significant findings. It rechecked the one-file delta and exact
candidate/content/caller bindings, passed 12 in-memory sanitizer probes and
verified frozen-core diagnostic propagation with synthetic provider stubs.
The existing invocation's returned metadata again identifies GPT-6 Astra.
Candidate-bound release qualification remains separate; none of the application
changes is deployed.

Canonical maintenance now admits the original accepted custom resource-group
name in v2 while retaining v1's conventional-name rule and exact original
target/ownership/configuration/capability/SKU/schema checks. The real local-only
request passes with live/build/execution readiness false and input bytes
unchanged. Shared read-only Admin UI helpers verify the exact promoted
predecessor separately, preserve original ARM/image evidence and all receipts,
and recheck that predecessor after complete Full verification. Future UI tool
provenance hashes both driver and shared helper. The `dea` predecessor passed
fresh live read-only checks at 2026-09-24 06:53 UTC.

The complete live verifier then correctly detected a different boundary:
Azure reported B1 for the executor plan, but the original accepted state requires
B2. The actor/time of that drift is unknown; scoped Activity Log reads returned
no events. A single scoped resource update restored the exact owned one-site
plan to B2/one worker at 2026-09-24 07:23 UTC. Original host identity, private
networking, authentication, roles and package-setting checks passed afterward;
original state/configuration bytes stayed unchanged. Preliminary unsupported
metadata-read attempts stopped before any update. No application deployment,
policy replay or reference registration occurred.

Maintenance regressions also reproduced rejection of healthy
`RunningAtMaxScale` revisions. The shared revision-state predicate now covers
all six Full-maintenance gates and the UI-only check, without relaxing exact
revision, health, replica count, probes or independent replica readiness.
The post-restoration complete Full readback isolated a remaining final-image
check that still expected the bootstrap UI image after the earlier independent
promotion check passed. Actual API/worker images matched their original digests;
the actual UI matched `dea`. Regressions reproduced this duplicate-check
inconsistency; every final live check now uses the verified predecessor while
the original `immutableImages` report stays unchanged. The combined image/admission
fixtures pass 51 tests. Actual joint-gate regressions separately reproduced an
unreachable worker-preservation check nested inside the API branch. It now runs
for the worker too; joint and revision fixtures pass 47 cases, including protected
setting drift and unchanged v1 behavior.

Complete live canonical Full verification passed at 2026-09-24 08:07 UTC, with
original input bytes and in-memory state unchanged:
`sha256:719e33624018f02d39ad19779fc883418b116acd47f3c13ba17fabdf60455a7a`.
This is baseline eligibility, not a candidate approval, deployment or policy
success. No provider mutation was replayed.

Earlier canonical local Package and Prepare completed for
`sha256:f481e7f7b498b575728653f13fc01e2b36dcb7fa995d26259378b88ed7a1a252`.
All 723 packaged inputs match the fresh passing isolated baseline bytes; no
retained build prerequisites were borrowed. The canonical generated upload
allowlist and 98-file compiled migrator bundle passed integrity checks, and the
compiled model remains unchanged. These are not an independent source approval,
remote artifact build or deployment. Findings requiring changes will need a new
candidate, never overwritten frozen bytes.

The Azure validation workflow was restarted for this candidate, without reusing
the earlier UI-only completion state. Two canonical read-only Plan attempts
failed their fresh Full baseline child before producing a Plan. Direct canonical
Core verification passed again at 09:05 UTC; the actual baseline child through
native PowerShell passed at 09:28 UTC. The redirected `ProcessStartInfo` launch
then failed at the common native-command nonzero-exit boundary. Its underlying
command and classification are not yet established. Those direct passes do not
replace current canonical Plan admission. Bounded read-only diagnosis now retains
validated provider codes and trusted source frames, never raw provider bodies.
No application/provider mutation or receipt rewrite followed these failures.
A tested diagnostic using the same redirected launcher subsequently passed at
10:14 UTC, with original state/configuration unchanged and no native-failure
signature files. Production source was not patched. The earlier cause remains
unknown; this pass does not substitute for an actual canonical Plan. The reviewed canonical Build Plan also failed its actual child before saving a
Plan. Another actual child diagnostic passed at 10:54 UTC; no cause is inferred
from that intermittence. Attempts to retain failure frames also exposed a local
diagnostic mistake: PowerShell localizes both frame separators and line labels.
The canonical launcher now retains only bounded, existing relative source-file/
line locations, without provider bodies or absolute paths. Real isolated-child
regressions reproduced the missing context and now pass in English/Korean,
including rejection of a success marker from a nonzero-exit child. All 44
baseline/provider diagnostic tests pass, with zero skipped/unrun cases.
The actual corrected canonical baseline process passed at 11:14 UTC; the earlier
native failure cause remains unestablished. New clean verification passed all
1,454 .NET and 447 Pester cases plus the three portable gates. Canonical Package
froze replacement candidate
`sha256:d7613ff791354dc6d25c6e2d87ce43d58626eb920221c314403be39e57834ea3`;
all 723 inputs match the fresh clean source. Its only packaged difference from
the previously reviewed candidate is `operations/GatewayUpgrade.psm1`.
Content source is
`sha256:72ccd87be4a2c472e5e609ac56d9dbd26f2b0842db620c116f060f4f138dc12a`;
artifact source and compiled model are unchanged.
Selected Prepare receipt
`.maintenance/validation/a9761cd716e84e759cbeea7ce4e9c6de.json` pins the 98-file
bundle with fully qualified candidate paths, and its exact local Plan checks
pass. An earlier relative-path Prepare receipt is not selected; no receipt was
edited to change its binding. The genuine source-review follow-up is approved and
separately recorded in
`.bootstrap/novice-protection-20260924/source-review-d7613ff79135.json`.
The real corrected reviewed Build Plan passed at 11:50 UTC, after its own current
canonical baseline readback at 11:49 UTC:
`sha256:8a19f9094c304872c8f401126cc6d278811fe43fd6e90e98ffc6a1d450b3f432`.
Its saved fingerprint, candidate/content/caller bindings and genuine source review
were rechecked. It permitted Build, not Execute. Both actual Build attempts
stopped during their fresh read-only verifier, before any action checkpoint.
The first failure was inside runtime-deployment evidence; three bounded checks
of that exact function passed without establishing its original cause.
The second exposed the exact generic resource-metadata read. A narrow probe
reproduced `NoRegisteredProviderFound` for existing Storage because CLI selected
API `2026-09-01`. The same resource and the other four RBAC targets passed twice
with explicit reviewed versions; `Microsoft.Storage` is already Registered.
No registration, governance, credential or resource change was required.
Both remaining generic metadata loops now pin their eight resource reads.
Real-loop regressions reproduced the missing versions, and all 55 combined
metadata/baseline cases pass without changing mismatch or failure handling.
The corrected source passed a new 961-input/74-source clean Release build with
zero warnings/errors, all 1,454 .NET tests including owned SQL, all 465 Pester
cases across 14 files, all three portable gates and unchanged-source guard.
No cases were skipped/unrun. New immutable candidate
`sha256:c9fec9e26fc53edf9bffce00dc47b55cb8063708d9172b75b2af1d24fb879205`
has 723 inputs, all matching those tested bytes; its only packaged changes from
`d7613ff7...` are the two metadata modules. Content source is
`sha256:cb991cf81582bdd2e6ea0b89e7d1021f4055f8a07c110f92abb8e039ee9133ba`;
caller verifier is `sha256:c3f428830ef446710e60f43ef001de6cede033e9b063f06af2ef3e778094f2c9`.
Absolute-bound Prepare
`.maintenance/validation/2cbc086504e042589cd703bf9017a6fb.json`
pins 98 files, unchanged compiled model and new artifact source
`sha256:90f5746d5fb5362ebbdf3197385e49451ad5e6f6b2c8c369ada60a4d30ef1f60`.
The actual redirected canonical Full verifier passed at
`2026-09-24T12:47:29.2794673+00:00`, preserving original input bytes; result is
`sha256:28613a992b2662a0020685dd91abf8b490c573f2a40fec03c8ed468a9269b7df`.
The genuine GPT-6 Astra reviewer approved this exact replacement source with no
significant findings. It independently checked all bindings and the two-file
delta, cross-checked API versions, parsed the changed subjects and passed all
18 finite metadata regressions. Full suites, Prepare and live readback were
supplied evidence, not rerun by that review. Its distinct record is
`.bootstrap/novice-protection-20260924/source-review-c9fec9e26fc5.json`.
Fresh actual Plan admission and independent saved-envelope binding checks now
pass for this reviewed source:
`sha256:a3cb51837bf5b5de7827938092b8ea87a90989848a1103c96b93bf0c2c5f3c8c`.
It permits Build only, not Execute. Canonical Build passed its fresh baseline
gate and produced API/worker/Admin UI/migrator runs `deb`-`dee`. It then stopped
before package creation because the default PowerShell 7.6.6 launcher does not
meet the pinned 7.6.5/X64 package contract. The actual unchanged prerequisite
check reproduced that failure and passed with the already-owned Microsoft-signed
7.6.5/X64 installation and EOM 3.10.1. The same approved Build completed with
that exact launcher, retaining completed image checkpoints rather than creating
another candidate or rebuilding those images. Publisher run `def` completed
the five-image bundle `6bf1f7fc...`; canonical Windows ZIP is `05f3ade2...`,
193,810,238 bytes, with manifest `dba4690d...` and receipt `c7ca5d8d...`.
No version/signature guard or system installation was changed.
Earlier candidates, approvals and the nine reviewed
non-secret source-scan findings for `d7613ff7...` remain bound to their own bytes.
An independent new local scan of `c9fec9e2...` produced nine fully redacted
findings and no scanner error diagnostics. Every current finding's file, rule
and exact source-line hash matches individually inspected non-secret content:
six public role IDs, one public application ID, one credential object name and
one source-file hash. The new report and review are bound under
`.bootstrap/novice-protection-20260924/qualification-c9fec9e26fc5/`;
this is not a zero-finding scan or release-artifact acceptance.
Fresh OCI digest/platform/non-root checks and all regular layer/config scans
pass for all five images, with zero findings or scanner errors. Byte
reconciliation covers 24 unique layers/8,594 regular files; repeated extraction
across images accounts for 20,426 regular files, without Windows path collisions.
Actual API/worker contract assembly bytes and all 14 migrator SQL/source files
match. The exact 1,367-file Windows ZIP was manifest-reconciled and scanned
without findings/errors, matches the publisher's embedded bytes and passes
six isolated native/HTTP checks. These are local artifact results, not hosted
authorization or provider acceptance. No application deployment has occurred.
All three frozen maintenance Bicep templates compile without changing their
bytes. Their static scoped role declarations and the target's inherited Azure
Policy definitions/parameters were inspected without changing governance.
Complete policy evaluation and exact artifact-bound ARM validation/What-If remain
pending.

The separate actual artifact-bound Plan
`sha256:9c023bfe040189a544f0a24fe1746a81d3fd5a8d74d103c4021d69b9782141e7`
passed canonical admission with Build and Execute supported. Its exact read-only
preflight then failed at the workload snapshot: Azure returns `containerapps`
in the API/worker ARM IDs, while the checker compared `containerApps` using
case-sensitive equality. Independent metadata readback confirms that ownership,
original source, environment, immutable image, Single revision mode and
Succeeded provisioning match. AppLens remains unavailable through the current
MCP authentication; the pinned native Azure CLI reads succeeded. This is a
checker defect, not evidence of changed resource identity or an application
incident.

The correction uses ordinal case-insensitive equality only for ARM resource
identities and rejects duplicate casing aliases across revisions/replicas. It
also reaches the private platform observer and preserves canonical Plan,
fingerprint, principal, image, phase and readiness controls. The private observer
must recognize `RunningAtMaxScale` as a revision state, while replicas still
require `Running`. All 89 directly affected tooling tests pass, including 24
finite private-observer regressions. All 92 actual-consumer PowerShell cases pass,
including exact close-only sentinel exclusion and duplicate-alias negatives.
Fresh actual snapshot/complete-revision calls passed for the three owned apps at
15:29 UTC: 2/14/6 revisions and one active each, preserving original identities,
source, environment and endpoints. Original state/configuration bytes are unchanged;
there were no mutations. The source-bound read-only diagnostic is
`.bootstrap/novice-protection-20260924/working-arm-identity-readback-e56a172552bd4370ab96b66bd7fcf2d6.json`;
it is not Plan approval or deployment evidence. No old frozen source or approval
was overwritten.

The replacement clean baseline passed from
`.test-work/m1-9073083c3e804f3783fbb1ebbd6a9008/source`: 963 authored inputs,
75 PowerShell parses, a zero-warning/error Release build, all 1,478 .NET cases
(including 138 owned-SQL cases), 510 StrictMode Pester cases across 15 files,
three portable gates and the unchanged-source guard. None were skipped/unrun.
Its evidence is `arm-identity-clean-source-verification-2.log` under the same
owned diagnostic directory. The first attempt remains failed evidence: one new
mock referenced an omitted switch under StrictMode. Its explicit switch binding
is corrected, and all 92 focused cases also pass under StrictMode.

Canonical Package froze replacement
`sha256:d9c98751d11c98e4f635908ad621db5af48a1a273c7411a97a117614872d6df4`.
All 723 inputs independently match that passing clean copy; exactly the five
production ARM-identity/readiness files differ from `c9fec9e2...`, with no
additions/deletions. Absolute-bound Prepare recorded
`.maintenance/validation/aafc1a0b45ab41fd9aacafd879a86235.json`, unchanged model
`96ab3daee7b7...` and artifact source `7a9603a8142c...`. A fresh local scan reports
nine findings, each inspected as a non-secret public identifier, object name or
source hash; it is not a zero-finding scan. Genuine GPT-6 Astra bounded review
now approves this exact source, with no significant findings. The review record
is `.bootstrap/novice-protection-20260924/source-review-d9c98751d11c.json`;
content source is `d211d329bb34...`, caller verifier `1d824ca72c06...`.
The reviewer independently checked the five-file delta and all source/caller
bindings, ran 92 StrictMode Pester cases and directly invoked 24 compiled finite
private-observer tests with portable-PDB checksums and byte guards. Full-baseline,
Prepare/model, SQL and live diagnostics are supplied evidence, not independently
rerun. There are no new release images/packages or application deployment.

The bounded inherited-policy assessment is complete for historical c9/9c,
retaining its 15:11:47 UTC observations and no deployment approval:
11 assignments, seven initiatives, 318 definitions/330 rule occurrences and
zero exemptions. No resolved Modify/DeployIfNotExists/Append predicate matches
its 17 proposed write scopes. Three preview selectors cannot be resolved to
published versions; current GA definitions are not substitutes. Write-time
MFA/authority and actual artifact-bound ARM/What-If remain independent gates.
The report is under the historical qualification's
`policy-readback/final-policy-assessment.json`; it does not approve d9.

The actual d9 reviewed Build Plan attempt failed the private host guard at
`bootstrap/modules/PurviewExecutor.psm1:562` before saving approval or starting
Build. Independent readback confirms B1/size B1, one worker, Windows/Ready,
correct plan association/private outbound routing and Resource Health Available.
Resource Graph proves two distinct changes: the original CLI B1-to-B2 restoration
at 07:22:01 UTC and a B2-to-B1 change at 15:36:55 UTC. The latter correlation
`060d4321-4671-4b24-abf0-866753e2bb9c` identifies application
`a1a9c5b6-7a4f-4288-89ab-6805873f65d1`, independently resolved in the project
tenant as `MCAPSGovernance-AutomationApp`. Its issuer/managing tenant matches the
subscription's `MCAPSGovernanceAutomation` delegation. No foreign-tenant sign-in
was used. A resource-ID-filtered Activity Log read missed the later event;
the exact correlation lookup recovered it. A separate transient native DNS
failure recovered without configuration changes and is not the SKU cause.

Source-bound failure evidence is `source-only-full-plan-d9c98751d11c.log`;
the selected non-secret drift/actor evidence is
`executor-sku-governance-drift-060d4321.json`, both under the owned diagnostic
directory. The exact governing automation rule/schedule/approved exception is
not established. Its linked internal guidance requires separate corporate
sign-in; no credentials or bypass were attempted, and the task-owned tab was
closed. No second restoration, governance/RBAC/tag change, original-input rewrite
or application deployment occurred.

The delegated local-evidence lookup is now complete. It found no server-farm
SKU write among 335 retained definition/version files or 47 resolved
Modify/Append/Deploy rules. The app/local principal appears in assignment
authorship metadata, not a scaling rule. The nearby
`MCAPSGovAuditPolicies / Lighthouse_Validation_Audit` v1.0.0 only audits
registration-assignment names; it is not an automation exclusion. The snapshot
ends at 15:11:47 UTC, before the second change, with three unresolved preview
selectors and no workflow/runbook inventory. The exact remediation is therefore
still unproven. No further Azure calls or changes occurred in this lookup;
no review remains running.

The user subsequently resolved the desired-size decision by explicitly selecting
B1. Quota and provider reads report regional limit 13/usage zero, but the generic
quota entry is marked not applicable; the decisive allocation fact is the
existing Ready Windows B1 plan with one worker and no net-new capacity requested.
The plan's selectable B1 capacity is one to three. This does not prove runtime
or provider acceptance.

Next: test and freeze the explicit B1 selection contract and fresh-install default,
independently read back the retained baseline and generate a fresh canonical
reviewed Build Plan; build and qualify the new exact
artifacts, then obtain their separate artifact-bound Plan and prescribed
validation for canonical **full source-only maintenance**. Do not Execute the
known-defective `9c023bfe...` candidate or relabel its evidence for this fix.
UI-only promotion cannot ship the API/worker/executor changes.
The existing `dea` deployment remains the hosted baseline; its receipt/validation
does not authorize the current source. Earlier genuine source-review provenance
is retained; replacement-source review is separately recorded, while actual Plan,
artifact approval and deployment
acceptance remain separate gates.
Complete the whole-project
documentation synchronization before closing the reopened items or starting
dependent M6 work.

## Working baseline and authorization

The user deliberately deleted the original supporting files and Azure resources,
then identified the retained application as a working baseline. Historical
deployments, repair targets and generated binaries are not current authority.
The starting Git checkpoint is `24bc24a` on `main`; authored M2-M5 work remains
uncommitted and must be preserved.

All Azure work remains in tenant `ff8b1e46-ff0f-4bc2-ab02-caf2b92da496` and
subscription **internal-security-lab-02**
(`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`). Reuse the supplied administrator's
authorized session. Never request the previously supplied password again or copy
it into project state, logs or commands.

On 2026-09-22 the user authorized all resources needed to complete M5 without a
cost ceiling, with M6 to follow only after full M5 closure. Preserve unrelated
resources and unknown outcomes. This does not authorize treating an incomplete
check or a runtime receipt as milestone completion.

Use installed Chrome or Edge. Direct browser control was authorized on
2026-09-19; the extension is optional. Synthetic browser fixtures use isolated
profiles and do not establish real Microsoft authorization.

## Source and product context

Setup, DatabaseMigrator and LiveVerification sources and bounded unit, SQL,
provider, worker, UI and source-contract fixtures have been restored. Use the
[local baseline runner](../tools/Test-LocalBaseline.ps1) with `-IncludeSql` for
fresh authored-source validation. The SQL category is `SqlServer`; generated
bin/obj output, skipped tests and arbitrary operator-script discovery are not
baseline evidence.

M2-M4 established the [UX design package](ux/README.md) and implemented core
onboarding, immediate one-time key handoff, delegated Registry progress, keyset
listing, lifecycle management, focused protection settings, expiry-aware
readiness and approved private runtime samples. Their precise acceptance remains
on the milestone items. The prototype is not the actual-component browser host.
Preserve the identity, consent, receipt, shared-policy, deadline and late-session
ownership learnings in [AGENTS.md](../AGENTS.md).

The restored application still distinguishes registration, configured policy,
current protection and telemetry delivery. Agent 365 Registry remains an
explicitly acknowledged development preview. Fresh compliance provider
references, short-lived readiness and the telemetry delivery-evidence limitation
remain real constraints; M5 infrastructure health does not erase them.

## M5 qualification environment

The corrected qualification configuration is
`.bootstrap/m5-corrected-20260922/config.json`, project `a365q5b`, environment
`dev`, region `koreacentral`, resource group `rg-a365q5b-dev-20260922`. Ownership is
`912b63ad-5b38-4fcd-b528-f898c013685e`. Its exact accepted Plan is
`sha256:64a2c5a579f89246fa9f0648f3593b871f30cb6cd865305004a70ac94695ffcd`;
configuration fingerprint is
`sha256:f8a695abf679e183a22713866d8f9c0e0b223fda7b79569216210b1b74be2f6b`.

Canonical Apply completed all stages. Post-deployment endpoint, telemetry,
private executor and restored-scale checks also passed. Separate canonical
Verify passed at 2026-09-22 09:03 UTC, after restoration. The exact state is
`.bootstrap/state/6f6ae863-dcb7-456f-a7f0-d6f9887cfb76-rg-a365q5b-dev-20260922-dev.json`.
Preserve its accepted source snapshot, source/configuration/Plan bindings,
private SQL completion receipt, identity evidence and one-shot publisher state.
Do not replay deployment or package creation to recover an uncertain result.

Qualification endpoints, not M6 product-acceptance endpoints:

- [Admin UI](https://ca-gateway-admin-dev.lemonisland-ab59593a.koreacentral.azurecontainerapps.io)
- [Gateway API](https://ca-gateway-api-dev.lemonisland-ab59593a.koreacentral.azurecontainerapps.io)

The private Windows executor returned Ready to the exact worker managed identity
with the corrected source/package binding. Its first cold read timed out and was
not accepted; one bounded read-only retry passed. This is not a Purview connection,
inventory, policy or enforcement claim. The temporary worker minimum was restored
to zero with image, identity, configuration and other scale bindings unchanged.
No registration, Registry completion or policy authoring was used as a substitute
for M6 journeys.

The earlier `a365q5` / `rg-a365q5-dev-20260922` environment remains intact under
ownership `13be97aa-23ca-490f-93d4-e38f81c8c8fb`. It is historical qualification,
not the corrected release. Both environments use S0 Content Safety, leaving the
future M6 configuration's F0 choice unchanged. Both remain retained and billable.
There is no generic destroy command. Cleanup must identify only owned resources
and tenant objects, preserve uncertain outcomes and respect the applicable
authorization.

## Exact artifacts and validation context

The corrected frozen authored-source archive is under
`.bootstrap/release-qualification/m5-corrected-daac8a85b0af48dd828cc84fc3861819`.
Its deployment-source fingerprint is
`sha256:e03180c2b9e7b2fe57b5cc05c59f96730acd6a5a0049a96fa30a36110879bc0d`;
the source ZIP hash is
`b8eac2d12b13d630b39a17efec6b4f18fd935f798bdd6dbd3d27ab123b4ea60b`.
The complete clean-source baseline and independent corrected-code/artifact
reviews passed. The archive remains immutable when continuation notes change.
Bootstrap/infrastructure READMEs are deployment-hashed inputs; final status
synchronization must leave the corrected deployment fingerprint unchanged.

Canonical q5b installation built the Windows ZIP
`sha256:65033fcc7c86217f2745e195aeac11d161edb103886d604810651c10dcf8ab08`,
with runtime manifest
`sha256:70098cddc53adfc0665b8489eecc0bb63657475ed76d72bd2ff0dd6cda66a5fe`.
Native checks, local redacted scans and private Ready used those exact bytes.
The immutable publisher embeds that ZIP, not an earlier package. The canonical
state retains every immutable image, package path and binding. API and worker
have matching corrected contracts, including durable protection attempt generation.
Deploy matching producer/worker releases; old strict workers reject the added
field, and unbound legacy current work requires explicit reconciliation.

The old q5 archive remains under
`.bootstrap/release-qualification/m5-27e20a51299448bc82e6cd92c1178b1c`, source
`sha256:2bb36ed7e638d7c398915ef383ec45fee580ed8a33ddc1c4a08ef574a9b1ccbd`,
ZIP `eb234b57d490348894c878b26aa37a890e085795329e3c0da8b913c1c82b9c8a`.
Its hosted `d86ba3f7...` Windows ZIP and the earlier local `a9bd...` ZIP remain
different artifacts. The intermediate documentation-only `e1909506...` source
hash is not a corrected release either. Do not relabel any historical receipt.

Reusable task-owned probes are under `.bootstrap/m5-20260922`; corrected
image/package/probe metadata is under `.bootstrap/m5-corrected-20260922`.
Results belong only on the M5 checklist items. Short owned source paths avoid
Windows native DLL path limits. Scanner error diagnostics and empty telemetry
queries were rejected, not counted as success. The corrected canary check used
the exact q5b workspace, all API request-trace positive controls and UTC-preserving
receipt parsing. This is application/console redaction evidence, not a per-event
downstream telemetry delivery guarantee.

The workstation's Linux Docker engine still lacks WSL; no OS feature, reboot or
global engine setting was changed. Linux images were built through the owned ACR.
The pinned Windows runtime/scanner inputs remain in `.bootstrap/release-inputs`.

## Authentication recovery context

The earlier Azure-management MFA blocker is resolved for the verified session.
The single user-approved policy is `6500e34d-7262-4f9e-9a6a-b6a241cdcb26`, scoped
to the authorized administrator and Azure management. Its exact original intent
and independently verified scope remain under
`.bootstrap/m5-authentication/42c4c4d4-f954-4160-bc25-0df93958d34b`.
Do not recreate it, reset authentication methods or weaken MFA to recover a
session. A genuine new MFA challenge remains a user action, not a reason to ask
for the supplied password again.
A later Graph CAE `TokenCreatedWithOutdatedPolicies` response was resolved by
refreshing the same administrator's Graph session in installed Chrome. Actor and
scoped Owner/RBAC authority were reverified; no new credential request or policy
change was needed.

## User-requested live checks on the existing registration

After M5 closure, the user created `ktx-v2-agent-01` on q5b and requested real
synthetic traffic plus browser acceptance in Agent 365, Purview and Defender/
Sentinel. The selected Gateway registration is
`aba7a404-aa60-4bf2-9102-d9d0b273c5d6`, external ID
`agent-33dc65d76da34ba8ae2a3905a5095de9`, child Agent ID
`5654869d-9b6e-4db8-8253-9000999858cb`, blueprint
`4d46b01c-6e68-4533-a883-878cf55428d3`.

The existing first-registration wrapper and freshly rebuilt LiveVerification
tool ran on 2026-09-22 at 10:06-10:08 UTC. As tested, Agent 365 and Azure Monitor
were selected, Prompt Shields was On and Purview was Off. The simulator sent a
benign receipt-bound interaction and a synthetic prompt-injection evaluation.
It revoked only its temporary key and removed its exact temporary Entra grant,
principal and active application. The durable verification state is Completed.
Do not repeat that one-shot operation or rotate the user's key to gather more
evidence. No application source, policy, connector or security rule was changed.

Installed Chrome showed matching activity in the M365 agent Activity tab,
Purview DSPM/AI activities and Defender advanced hunting. The same record IDs
link the latter two surfaces. The block decision was observed in Gateway/Azure
Monitor telemetry, but no matching Defender behavior or alert was observed in
the bounded query, despite Security for AI being enabled and its Microsoft 365
connector connected. The Sentinel browser view filtered to lab-02 had no
connected SIEM workspace; the exact q5b workspace also returned Sentinel NotFound
from ARM. Do not generalize this into resource absence in other subscriptions.

Purview activity details displayed "Related activity not found". The exported
messages are redacted by design, and Gateway Purview was disabled during the
test: neither full content inspection, classification nor policy enforcement was
accepted. Only the activity mirror was directly observed in Azure Monitor;
the interaction mirror remains unconfirmed. Precise observations and acceptance
limits belong to M6's unchecked items, not a separate completion record.

Non-secret correlations, actual query metadata and browser screenshots are under
`.bootstrap/live-acceptance/20260922-ktx-v2-agent-01`; the canonical temporary-key
recovery record is under `.bootstrap/verification`. Preserve those owned records.
The user was navigating the original Gateway browser tab during these checks;
leave that tab and any user-held form state intact.

### Prior companion download and expired-command failures

The companion download was found at
`.playwright-mcp/Connect-PurviewTenant.ps1`, not the normal Downloads folder.
Its SHA-256
`e985e96da95566fe5890bdc7801a8d46440d0cbc2adff24acc46af54decf016c`
matches the authored companion and qualified served asset. This confirms
integrity, not a trusted-publisher signature.

On 2026-09-22 the user's shell rejected this file before execution. Read-only
diagnosis found signature NotSigned, Internet zone 3, and effective RemoteSigned
at CurrentUser and LocalMachine; Process, MachinePolicy and UserPolicy were
Undefined. This explains the Internet-marked unsigned-file restriction, not an
organization-wide AllSigned policy. An organization-permitted per-file
`Unblock-File` is normal RemoteSigned handling for an exact reviewed download;
it does not change execution policy. Enforced signing still requires an approved
signed copy. Do not lower policy or evade an enforced restriction.

The supplied launch for operation `b353bcf8-18c2-4b98-af93-70bc69e2a343`,
inventory generation `7a8ce2e3-7354-447f-b679-d12cb5058670`, expired at
2026-09-22 11:28:55 UTC (20:28:55 KST). This is launch expiry, not proof of the
durable operation's terminal status. Keep its original bindings; do not edit
the expiry. Resolve the file's applicable trust/signing requirement first, then
read the existing operation and obtain fresh reviewed authorization through
the Gateway when required. No companion execution or policy change was performed
by the diagnostic checks.
Later read-only inspection found that the saved file no longer had Internet-zone
metadata, while its signature remained NotSigned. The assistant did not remove
that metadata or change policy. Do not treat the earlier signing observation as
proof of a continuing execution block: the user's later bare invocation prompted
for mandatory arguments, and the expired website handoff was a separate issue.
Use the complete freshly issued command rather than manually entering old IDs.

On 2026-09-23 the user ran `Unblock-File` on the verified Downloads copy and the
script subsequently executed. Its first failure was an already-expired command,
not another signing rejection. A later fresh command successfully returned 354
sensitive information type definitions. The assistant did not change the user's
download, execution policy or expiry. Those definitions are a catalog, not
captured prompt/response content or a DLP policy.

### Deployed expired handoff website repair

The user then demonstrated a separate application dead end: the page called the
connection expired but disabled both its fresh-review action and completion.
The API already supports a new reviewed/confirmed authorization; the UI was
unconditionally blocking AwaitingAdministrator, including expired launches.

The correction preserves the old operation, keeps its expired command invalid,
and permits the new review only with current connection/row-version checks.
A retained operation additionally requires matching actor, tenant, target and
canonical launch/expiry. Pending verification, running work, unknown outcomes
and mismatches remain blocked. No SQL reset or manual authorization edit is used.
The existing UI upgrade helper also now requests machine-readable What-If with
no-op Ignore entries excluded; its strict mutation allowlist is unchanged.

Local component, isolated Chrome and upgrade-guard checks passed. Azure
prepare/validate completed before the canonical Admin UI-only command accepted
upgrade Plan `sha256:d278be419bcd3efe11e865308ed923860b95f52c7553b7c907e4e08a368b50e1`.
Working build source:
`sha256:3f3c356c5f0a04630aa7f4520444a5dbf4487abe0a22c5cddaa233fa5c4f082b`;
separate upgrade source:
`sha256:4268220298e6e8a4e9710b83d145451ebc2386123d944e6442f8872102a6fdbc`.
ACR run `de6` and ARM deployment
`a365gw-a365q5b-admin-upgrade-4268220298e6-dev` succeeded. That upgrade's UI digest:
`sha256:e4500a152cc198db4bcbad65b4d7c2e8ec41e94f8412d9742863cfd386f712a0`.
Actual Chrome confirmed the enabled fresh-review action on the
original expired operation and obtains its normal server confirmation. The
diagnostic review was cancelled before another timed launch was started.

The original upgrade's final checker rejected Healthy RunningAtMaxScale,
although the exact new image was already healthy and ready at its configured
maximum of one replica. Its accepted tool snapshot
`accepted-upgrade-tool-b39a23bb.ps1` is retained under the repair's operational
directory. The canonical receipt
`.bootstrap/evidence/rg-a365q5b-dev-20260922/admin-ui-upgrade/1b6db052527e49dc0ff9db6b4fc73767ec38ed0b80018af9cc1afe9e5c4191fb.json`
remains unaltered: deployment Succeeded, overall status Accepted. Do not edit it
to claim the original checker passed, or rerun a different tool source against
that accepted mutation intent.

The narrowly corrected read-only verifier accepts Healthy RunningAtMaxScale,
records the observed state and rejects unhealthy/stopped/empty revisions.
Its exact source delta from the accepted tool was checked before a separate
readback. That verified image, revision, identity, scoped roles, HTTP endpoints
and unchanged API/worker/queue/bootstrap bindings at 13:00 UTC, without replaying
any cloud mutation. The proof is
`.bootstrap/expired-handoff-20260922/post-deployment-readback.json`; original
tool, verifier and readback-script hashes are explicit. API/worker/SQL/Windows
artifacts and original bootstrap Plan remain unchanged. Client script-signing
controls were not altered by this UI repair.

### Current completion-recovery correction and separate provider failure

The successful helper result belongs to connection operation
`6708b4ea-f0ed-4a9b-85d6-8c1602bc3b4d`, observed at 01:52 UTC on 2026-09-23.
The completion approval has a different ID. The API correctly accepted the
result and resumed the original operation, but the UI expected the approval ID,
reported a false response-mismatch error and retained the wrong recovery link.
Do not rerun the helper, resubmit its accepted result or edit the original task.

The current source correction retains and expects the reviewed original
connection ID before confirmation/mutation, recovers unknown results by GET and
can follow an older Submitted approval's validated source reference. Confirmation
still binds its own approval. Pending/unknown completion hides the helper;
failure codes and explicitly UTC times are visible. The fixtures now use
distinct IDs and the real resource state `VerificationFailed`, not the
operation's `Failed` value. Current component, fresh actual-component Chrome
and core regression checks passed. The canonical Admin UI-only upgrade and
hosted existing-operation readback also passed, as recorded in
[the active deployment plan](../.azure/deployment-plan.md).

Canonical promotion finished Verified at 04:28 UTC on 2026-09-23. Accepted Plan:
`sha256:e47c7360729cb83ad161cdc0a47162b1f8a46db26cfbaee9aefd49ed44abc9a0`;
build source:
`sha256:ab9be6b7b2218d230e97da69bab67d379b1bcde612543a3f8af25b806e1cfbd1`;
upgrade source:
`sha256:891c9853fa97fbc267310d5ad8fc372f3e77d284d149d0bf5193914f1f4db578`.
ACR run `de7` produced that correction's UI digest
`sha256:65d5d4e5cc9f9ae32e1df5fd3fde104425d6a7b12e657c0e4f770e09fbac10b9`.
Deployment `a365gw-a365q5b-admin-upgrade-891c9853fa97-dev` succeeded;
revision `ca-gateway-admin-dev--0000002` was verified healthy at that time.
The first-run correction below subsequently superseded it. Preserved receipt:
`.bootstrap/evidence/rg-a365q5b-dev-20260922/admin-ui-upgrade/6114fd4618dc20493db2f4013aa61db939a24ae021742056235b58c347fe4137.json`.
The original bootstrap state and earlier Accepted receipt remain byte-for-byte
unchanged. API/worker, queues, identity, exact registry/secret roles, network
boundary and Entra redirect checks passed without unrelated changes.

Chrome renewed the existing administrator browser SSO and reopened the original
failed operation. Read-only refresh and ten DOM checks passed at 04:33 UTC:
the correct retained ID, plain-English steps, actual Failed state, bounded
failure/correlation references, UTC times, no stale helper and enabled reviewed
refresh. The screenshot was inspected. This did not create a new review,
resubmit evidence or verify a fresh live completion; provider access remains
separate. The owned synthetic HTTPS fixture was shut down gracefully and its
certificate disposed.

The original connection retains a separate real backend failure: it reached
Discover Provider State and failed with `PURVIEW_CONNECTION_PROVIDER_UNVERIFIED`
at 01:57 UTC. Correlation ID: `29b80514-0ec7-4992-8f32-f56702d8bf20`.
One separately identified read-only app-identity diagnostic at 02:37 UTC reached
the exact private Windows package and failed at verifier stage 8,
`Get-ServicePrincipal` and its ObjectId/AppId readback. That established the failed
boundary, not by itself whether a reference was absent or denied.
Its bounded metadata is retained under
`.bootstrap/connection-completion-20260923`; no provider body or token was logged.
The temporary worker minimum was restored to zero with its original artifact,
identity and configuration. No original workflow, SQL, receipt or policy was
changed by that diagnostic.

At 03:14 UTC, a separately owned native Windows administrator session successfully
read both provider references and found no match for the exact enabled Entra
automation AppId/ObjectId. That read confirmed the missing Security & Compliance
reference. The existing broker session worked in a real console; earlier
headless/external-token attempts did not. No password or execution-policy change
was needed for that read. Subsequent bounded registration attempts did not
complete native sign-in and were stopped before the create-intent/dispatch
boundary. Those attempts created no reference. After Gateway browser
SSO was renewed, a separately bounded official device flow still required
password reauthentication for Exchange PowerShell. That flow was cancelled
without entering a password or reaching any create intent; no MFA challenge was
observed. The owned process and authentication tab were closed, and absence of
intent/result/unknown records was checked at that time.

The user subsequently completed the guarded reference registration at 06:09 UTC
on 2026-09-23. Operation `78d577bd-860b-435e-a828-cc896ca35823` returned
`ExactReferenceVerified` for automation AppId
`d8c96405-1209-4a05-a969-315509e9b36c` and enterprise ObjectId
`46bc220c-1d9d-413c-8c33-02146eb3cfc5`. The persisted result matches its exact
intent hash: one reference created, zero role or policy writes, and unrelated
references unchanged. Do not rerun registration or upload this repair JSON as
the Gateway's companion-completion evidence.

A separate app-identity `VerifyConnection` read completed at 06:26:39 UTC:
`c528d43f-6785-4b18-853c-bff81930082c`, HTTP 200, Completed, 354 definitions,
no failure code and explicit remote exit zero. It used the qualified worker
identity and private executor, verified exact evidence identity/operation/time
bindings, and retained its bounded result under
`.bootstrap/connection-access-confirmation-20260923`. An earlier diagnostic
`c37d795d-2635-4662-994f-d056e126a3e0` did not yield a captured semantic result;
its subsequent GET-only health readback had no matching cached diagnostic.
That attempt remains unconfirmed, is not counted as success and was not replayed.
The successful read is a separately identified, bounded provider read, not a
Gateway connection or policy mutation. The old failed Gateway operation remains
unchanged. A later fresh user connection completed at 06:50 UTC, as recorded
below; DLP enforcement remains unverified.
The temporary worker minimum was restored to zero at 06:27 UTC with its exact
image, identity and configuration invariant verified. Original bootstrap and
predecessor-upgrade receipt bytes were rehashed unchanged.

Deployment preparation also identified that a second Admin UI upgrade cannot
assume the original bootstrap image is still live. Canonical successor admission
now independently verifies the exact prior upgrade, retains its original
Accepted receipt unchanged and binds that proof into a new Plan. Its 165
synthetic guard cases and fresh live admission passed before the successful
promotion above. Do not reset bootstrap state or replay an earlier deployment
to get around this boundary.

### First-run companion UX correction

The user subsequently completed a fresh connection. Live read-only Chrome
observation at 06:58 UTC on 2026-09-23 showed **Connection verified**, last checked
06:50 UTC, with 354 definitions (355 options including the placeholder). Its
displayed review expiry was 07:05 UTC. This is time-bound evidence of that
completed connection, not permanent readiness or DLP enforcement. Do not rerun
the helper or resubmit that accepted result.

The user's next feedback identified two first-time UX defects: per-file download
trust was missing at the run step, and the website unnecessarily required a
manually created text file. The deployed correction gives six ordered steps,
including how to open PowerShell 7 in the download folder, a separate copyable
organization-permitted `Unblock-File` command and explicit signed-script-policy
limits. A blocked script cannot unblock itself because it never begins running.
No execution policy is changed and the companion script itself is unchanged.

**Paste companion result** is now the primary flow; uploading an already
saved result is optional. Both paths share the strict bounded decoder and
operation/tenant/administrator/generation/expiry checks. Editing invalidates
prior evidence/review, superseded file reads cannot replace a newer paste, and
raw text is cleared on submission or leaving the task. A finite shared 1 MiB
Interactive Server message limit supports realistic results above 32 KiB while
retaining the 512 KiB text and 384 KiB decoded limits.

Canonical UI-only promotion finished **Verified at 08:23:17 UTC** on 2026-09-23,
as recorded in [the deployment plan](../.azure/deployment-plan.md). ACR `de8`
produced the current UI digest
`sha256:4a72396900fe77e75bc088fd13446e09dad274ed4071e788fc19d9727b645d0f`;
deployment `a365gw-a365q5b-admin-upgrade-2125ab0333e6-dev` and healthy revision
`ca-gateway-admin-dev--0000003` match its exact source-bound receipt:
`.bootstrap/evidence/rg-a365q5b-dev-20260922/admin-ui-upgrade/e33e7c8feeda06b7159ecb477dcce8d511a89499afad2430cfed63031164038a.json`.
Only one build and one deployment were dispatched. Exact read-only recovery
resolved build/readiness verification failures; their uncaptured causes are
not inferred. Bootstrap and de6/de7 receipt bytes remain unchanged, as do the
API/worker, queue counts, identity/role scopes and network boundaries.

Authenticated Chrome readback passed at 08:25 UTC after existing-account SSO
renewal, without a password or new connection action. The page truthfully showed
**Refresh required**, last checked 07:05 UTC and review expiry 07:20 UTC. That
current metadata does not erase the earlier completed connection. Thirteen
read-only checks verified identity, no stale handoff, deployed companion styles
and unchanged companion download SHA-256
`e985e96da95566fe5890bdc7801a8d46440d0cbc2adff24acc46af54decf016c`.
No console errors occurred; the screenshot was inspected. The new paste flow
was exercised with realistic input in the actual-component Chrome fixture,
not submitted again to a live provider. No repair, connection or policy was
recreated to expose the controls. Verification and remaining acceptance limits
belong to [MILESTONES.md](../MILESTONES.md), not the operational receipt alone.

### Guided protection outcomes and continuation

The user's later screenshot exposed a different completeness defect: a completed
technical timeline had no plain-language outcome or next step. Authenticated
read-only Chrome at 10:34 UTC on 2026-09-23 observed a connection last verified
at 10:26 UTC, expiring at 10:41 UTC. Its success is historical, not permanent
readiness. The screenshot's operation ID was not established; do not invent it
or resubmit evidence to reconstruct the screen.

The current source now places **What happened / Why this matters / What remains /
Next step** above collapsible purpose-specific technical details. Connection
completion explains the Gateway's own app-access verification and classifier
inventory, then continues to shared policies. Policy outcomes preserve the exact
profile and distinguish Off, simulation, pending setup and Enforce requiring an
approved runtime test. Current runtime evidence leads to explicit agent choices
and separate telemetry verification; a historical/failed/expired result does not
become a current protection badge. Expected skipped connection steps are
explained as unrun, not passed.

Settings automatically observes only its retained pending operation by GET in
bounded three-second/five-minute sessions. Terminal readback refreshes current
context; failures, stopped updates, unknown outcomes and unavailable permissions
have explicit guidance. No observation automatically reviews, confirms, navigates,
creates policy, enables an agent or sends samples. Runtime readiness callbacks
refresh summary state without rebinding the private sample session. The parent
expiry boundary includes those effective readback deadlines, and refresh success
uses the same task-scoped read dependencies as the loaders. An unrelated retained
blueprint error can no longer trap recovery on the connection task.

Fresh source and actual-component Chrome checks cover the complete clickable
connection-to-policy-to-runtime-to-agent journey, recovery, expiry, roles,
keyboard, narrow layouts and actual 200% zoom. They found and corrected bare
fragment links escaping a nested task through Blazor's base URL and unstyled
screen-reader announcements duplicating visible text. Independent review found
the cross-task recovery and replacement-readiness expiry gaps above; three
actual-parent cases failed before the fixes. That de9 source passed 314 UI
tests, 144 fixture self-tests and 63 HTTP/isolation checks, plus 140 M4 and 180 M3
Chrome checks. Chrome directly exercises both review corrections. Worker-faithful
failure fixtures preserve manual-intervention semantics, untouched later steps
and cleared connection authority/inventory lifetime.

Renewed canonical preparation, official Bicep/ARM validation and Release publish
pass. Typed What-If shows only four existing Admin UI resources modified and no
create/delete; inherited policy applicability is unchanged. All 631 selected
code/build inputs still match the tested source copy after documentation-only
edits; documentation has its separate consistency gate. Exact proof
and scope belong on the restored
M4.3/M4.7/M4.8 items and the [deployment plan](../.azure/deployment-plan.md).
Bounded review follow-up confirms both fixes with no new significant issue;
it inspected source and persisted regression artifacts, not live providers.
Non-UX synchronization and structural checks pass on 943 stable authored inputs,
27 Markdown files and 321 local links, including current API/role/configuration
contracts. The initial prototype report did not cover subsequent alignment edits;
those were verified separately after matching the current runtime heading and
correcting a pointer-driven keyboard test. Fresh syntax and isolated Chrome pass
1,649 synthetic design checks, including manual Stop/Resume and terminal current
readback. Current desktop/narrow/200% outcome and recovery screenshots were
inspected; the owned browser/profile is closed/removed.
The canonical same-target UI-only promotion finished Verified at
2026-09-23 16:37:41 UTC. ACR `de9`, image digest
`sha256:5319998f45bc6a78f1ff9e1b4bd56291344759d1ab467659790ac9db4b1b6392`,
and revision `ca-gateway-admin-dev--0000004` bind corrected source `c37648b0...`,
combined upgrade source `fb3c382b...` and accepted Plan `3f151d43...`.
The exact receipt is
`.bootstrap/evidence/rg-a365q5b-dev-20260922/admin-ui-upgrade/50b3156f39ebae26ee35b50a09571f9c69a8717f6efa53da6c8b27a3ad2085b6.json`;
its SHA-256 is `04f35b706c52de362ecbf05987be79d893dc160f35893eeaca9c11178a72ab36`.
Original bootstrap/de6/de7/de8 bytes, API/worker images/revisions/configurations,
queue counts and identity/network boundaries remain unchanged. The protection
queue still has one pre-existing dead-letter. Exact registry/secret roles were
reverified live; the managed-identity client ID `447ef378...` is not the separate
web sign-in app `a32cf74c...`.

Authenticated installed Chrome passed 25 read-only checks at 16:42-16:45 UTC
after existing-account SSO, without a password or new consent. The live outcome
truthfully preserves the 10:26 UTC success while explaining expired readiness,
purpose, limits and Review connection refresh. Policy/runtime prerequisite links
were clicked back to that task. The screenshot was inspected, the announcement
is clipped, the served companion hash is unchanged, and no console errors or
warnings occurred. No review/confirmation, connection, policy, sample or agent
change was invoked. Current proof is under
`.bootstrap/guided-protection-reviewed-20260923/ui-validation`.
Local positive-journey proof and this bounded hosted readback do not establish
Microsoft-provider enforcement or downstream telemetry delivery.

### Companion submission recovery after the same-page shortcut

The later 18:08 UTC failure was a different UI defect. The API accepted three
completion reviews, but no subsequent confirmation or completion was observed
for original connection `0c9f53b5-fb09-4a03-aa1c-07013dc52540`, accepted at
18:02:46 UTC on 2026-09-23. Read-only reopening found the launch expired while
still awaiting completion. Neither that evidence nor its command can be reused.
No live review, confirmation or provider mutation was invoked to diagnose it.

The exact generic error was reproduced in the actual-component Chrome fixture.
**Go to companion result** adds `#purview-companion-output` in the browser, but
the server recovery URI lacks that fragment. The old guard rejected the harmless
difference before sending either confirmation or completion. This was not
invalid pasted evidence or a Purview permission failure.

The corrected helper preserves the browser fragment and validates the origin,
path, other query parameters and exact single recovery ID. Shared connection/
policy handling now identifies pre-dispatch acknowledgment, JavaScript,
disconnection and timeout failures explicitly, with reload/status/review guidance
and only safe operation-ID/error-type logs. Original-operation recovery,
separate approval IDs and the no-dispatch acknowledgment barrier remain intact.

Fresh proof: 146 focused cases; the latest full UI run passed all 320 cases with
zero skips. The initial full run had one timing-sensitive existing evidence-edit
assertion failure; its three isolated cases and the full rerun passed without a
production input-handling change. The new source-bound fixture built with zero
warnings/errors and passed 144 self-tests, 63 HTTP/isolation checks, 142 M4 and
180 M3 Chrome checks, plus 18 private-runtime protocol checks. The exact
shortcut/paste/review/submit path now completes once under the original operation,
without reloading after the shortcut. Two current handoff/recovery screenshots
were inspected. Browser identity, APIs and evidence are synthetic.
Component source is `0de23daaaafc0e992fa4b326f18ed154d9446954ca81b681d6faeab085e51388`,
module `9fdca9f2-c6cc-4a6b-8d3a-097e2353bbe6`; browser artifacts are
`.test-work/m4-browser-678025c9-a1b2-49fc-8389-ef9d0548c639` and
`.test-work/m3-browser-ee00e717-7b86-485a-a8b3-968f774f5d2b`.

Canonical UI-only promotion finished Verified at 2026-09-23 19:39:39 UTC.
ACR `dea` built image
`sha256:8a31d8faaeefef528bf74af78329baf71c3e8b1b3b8b523cbbdbb30aca374c24`,
now served by revision `ca-gateway-admin-dev--0000005`. Accepted Plan
`sha256:1c06570684c80c4ee6b0b1e909713e745afa0ec2aa351fe6d1d931e30770554d`
binds build source `1ea57567...` and combined upgrade source `50e8637f...`.
The receipt is
`.bootstrap/evidence/rg-a365q5b-dev-20260922/admin-ui-upgrade/ad8dacd74a8f63d1a8d17e45ae3ee6da1402c55f168ff24c0fc0cc77bbe6ffb9.json`.
The initial strict post-deployment health check failed; its receipt remained
Accepted, with a checkpointed digest and Succeeded ARM deployment. Fresh readback
then found one healthy active revision at 100% traffic. Resuming that exact
recorded intent completed canonical verification without a second build or
deployment. The failed check and successful recovery remain separate evidence;
the exact initially failing health subcondition was not captured.

All 746 deployment inputs, the original bootstrap and four predecessor receipts
remain unchanged. API/worker images, revisions and configuration, queue counts,
identities, network/secret boundaries and the exact registry/secret roles were
reverified. The protection queue retains one pre-existing dead-letter; no queue
messages were consumed or cleared.

Authenticated Chrome passed 22 served-asset/recovery-guard checks at 19:43 UTC
and six read-only refresh checks at 19:45 UTC, using the existing administrator
SSO account without a password, consent or MFA challenge. It verifies the exact
tested recovery bytes and unchanged companion, accepts the legitimate fragment
difference, rejects changed identity/query context, and restores the original URL
and history state. The original expired operation is truthfully explained,
paste is disabled, Review connection refresh is available, and a real GET-only
refresh updates the checked time without a generic error. The current outcome
screenshot was inspected; console errors/warnings are zero. No new review,
confirmation, connection completion, policy or provider sample was sent.
Compact proof is under
`.bootstrap/protection-recovery-20260923/ui-validation`; the
[deployment plan](../.azure/deployment-plan.md) retains exact delivery bindings.
Acceptance is recorded on M4.3/M4.7/M4.8, not these operational reports.
Documentation/contract synchronization and fresh structural checks passed.
Owned fixture hosts, profiles and certificates are closed; inspected temporary
source/build/publish copies and the preparation scratch script were removed.
Source manifests, red/green test reports, browser proof, accepted snapshots and
operational receipts remain. Do not launch a replacement timed connection until
the administrator is ready.

## Next action and fresh M6 target

M5 release acceptance is complete in the milestone checklist. Corrected canonical
Verify and final independent documentation/evidence review passed. Owned scratch
source/package/layer extractions were removed; source archives, accepted
snapshots, exact hosted ZIPs and compact evidence were retained and rehashed.
The original bootstrap and API/worker qualification retain `e03180c2...`; the
Admin UI-only expired-handoff repair above has separate source, image and
upgrade-receipt bindings. The newer completion correction has its own verified
Admin UI promotion and hosted failed-operation readback above. The missing
Security & Compliance reference is now registered, independent Gateway app
access passed, and the user's later fresh connection completed. The first-run
UX correction and guided outcomes are deployed as historical de8/de9 updates;
the newer same-page recovery correction is deployed and canonically verified as
`dea`. Its affected 18:02 UTC attempt expired before completion, so its old
command/result cannot be reused. When ready, the administrator can refresh the
Gateway, select Review connection refresh, review/confirm the new handoff, run
its newly displayed command, paste the complete fresh result and review/submit
it, then wait for independent Gateway verification. Do not ask the user to repeat
an earlier completed connection merely to demonstrate it. Future reviewed
handoffs use the complete
fresh `A365GW_CONNECTION_RESULT:` line directly in the paste field; a saved file
is optional. Start a timed handoff only when the administrator is ready. Do not
reuse old evidence, resubmit the reference-repair JSON, rerun the completed
reference repair or treat expired readiness as a failed historical operation.
The HTTPS-ingress and retry/settlement defects identified in the old release were
fixed, independently reviewed and qualified in the new exact candidate; neither
old health checks nor relabeled receipts supplied that proof. No commit or push
was made.

The fresh M6 deployment remains unstarted. Its preserved configuration is
`.bootstrap/m6-20260921/config.json`, project `a365m6`, resource group
`rg-a365m6-dev-20260921`. The corrected-source read-only Plan/What-If is
`sha256:b4c605cf8ffeb7a45719fe18581adfca8bd8015df8076d51ac5b836f0a174872`,
configuration
`sha256:71f05f20b32382c4dc81056c69cb7f4c73e587ed6c799b4233eba6d16605ce97`.
It compiled every bootstrap template and predicted foundation creates without
deletions. No Apply Plan was accepted, no M6 execution steps exist and independent
readback confirmed its group absent. The supplemental q5b observations do not
relabel qualification resources as M6 or close its broader scenario set.
Remaining work includes explicit security-event routing/alert verification,
approved Purview configuration and sensitive-sample behavior, full content
visibility requirements, and complete selected-destination delivery evidence.
Any change to message-content collection or shared policy scope needs its own
reviewed configuration; do not silently disable redaction or broaden a policy
to make a test appear successful. Before the fresh M6 deployment, repeat
time-bound validation and explicitly accept the exact source-bound Plan.
Do not restore a stale/deleted target.
