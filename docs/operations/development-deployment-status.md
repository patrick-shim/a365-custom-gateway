# Development deployment status

This file is the live-development source of truth. Read it after
[`../implementation-status.md`](../implementation-status.md) and before any Azure,
SQL, Entra, Service Bus, Graph, or deployment action. It records evidence, not
desired state. Current state is kept first; retained chronology below is explicitly
labeled historical and must never be mistaken for the resume point.

Last reconciled: **2026-08-30**. Continuous workflow-v3 registration,
automatic delegated Administrator completion, final Agent 365 verification,
registration-bound ingestion, Microsoft 365 Admin Center landing, and blueprint-
scoped prompt DLP and independent pre-model Prompt Shields are live in development.

The repository now contains a separate `bootstrap/` first-deployment state machine
for a clean subscription. Its disposable-target execution described below did not
run against the existing development subscription/resource group. None of the live
identifiers, queues, registrations, policies, or retained evidence below were used
or mutated by that bootstrap work.

## 2026-08-30 clean-subscription live bootstrap and recovery checkpoint

The corrected Phase 6 candidate is frozen on branch `codex/phase6-candidate` at
source commit `715bbf93dcefa95266f1ce7616f8d39ca137fa10`. The exact-account boundary now
acquires Microsoft Graph access through `az account get-access-token` with the
reviewed subscription, verifies returned subscription/tenant/type/lifetime
metadata, and sends only bounded Graph v1.0 requests through an in-process,
no-redirect client. Supported post-authentication code rejects native `az ad` and
`az rest`; the workflow-v3 helper also verifies that its loaded Common module is
the accepted-source file or a byte-identical source-bound copy.

The final local candidate gate is zero-warning/zero-error Release build and
**1,279/1,279** direct Release tests with the unchanged project split below.
Pester discovered **267** tests: **266** passed, none failed, and one Windows-only
launcher test was skipped on macOS. The canonical source gate parsed **16**
PowerShell files and **2** JSON contracts and compiled all **23** Bicep templates;
`dotnet format --verify-no-changes` and `git diff --check` are clean. Focused
bootstrap regressions pass **103/103** and architecture passes **113/113**.
Independent settled-diff correctness/security review found no actionable issue.
These are local-source results, not live deployment proof.

The first target-subscription Apply attempt used the earlier source generation
`560bcd8e6a735c4d7bb4bb2695622a0ba17b90d6`. It completed only local
Prerequisites, then failed during Azure authentication because the old dispatcher
appended `--subscription` to a tenant-scoped signed-in-user command. It reached no
provider registration, resource-group creation, ARM deployment, Entra mutation,
SQL action, or Agent 365 mutation. Both the original resource group
`rg-a365-custom-gw` and the new isolated target `rg-a365-custom-gw-phase6` read back
absent in subscription `6f6ae863-dcb7-456f-a7f0-d6f9887cfb76` on 2026-08-30.
The failed state/evidence remains preserved; it will not be rewritten under a new
source generation. At that checkpoint the next action was the isolated `a365gw2`
Plan/Apply recorded below. Subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` and all of its live/retained evidence remain
outside this bootstrap target and were not mutated.

The first fresh isolated Plan on intermediate commit
`da0726a50f6fa77a3810c2517530520e4b7b1c66` also stopped before acceptance and
before every bootstrap step because its new Graph boundary had not yet been given
the exact Plan tenant/subscription context. Commit
`603123a2f7097e2088e2620dde002cea0d4c37d9` establishes that context before both
ARM What-If and Graph collision discovery; the added regression is included in the
earlier 233-test Pester gate. That intermediate isolated state remains 0/19 with no
Azure or Entra mutation evidence.

The corrected `a365gw2` Plan then ran against only disposable target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Plan
`sha256:b062c6eb03899e2e902e1d92a7db33d5b0addcc73ce15c1712bf06b04296ec28`
bound resource group `rg-a365-custom-gw-phase6`, source
`sha256:077c357432f654c455edf0efc9edd8cc71b18fb887d4d5235b16fa6c913d0fbe`,
and deployment ownership `967d17d1-e0f5-494b-bae7-0e1f00faff5c`; authenticated
What-If reported exactly six Creates and zero Deletes. Apply completed
Prerequisites and was deliberately interrupted immediately after Azure
authentication started, before provider or resource mutation. Persisted status
showed 1/19 and the exact next step. Resume recomputed the identical Plan
fingerprint, completed authentication and provider registration, deployed the
foundation, and created/read back the project-scoped Gateway API identity.

The run stopped safely at **5/19** in `Immutable workload images`, before any ACR
build submission. The fresh registry `acra365gw2devg6gn55` read back healthy and
empty: repositories `[]`, task runs `[]`, and no image intent/evidence in bootstrap
state. The exact cause was Azure CLI 2.89.1 returning exit 1 for
`acr task list-runs --image <never-built-tag>` rather than `[]`. Foundation ARM
deployment `a365gw-a365gw2-bootstrap-foundation-dev` succeeded; the preserved
Gateway API application object/client/service-principal IDs are respectively
`d3ecf2fb-912e-4900-8bff-588b31320a47`,
`c23195bb-dea0-4c18-be3b-0b1f61fe3cc9`, and
`bca509d0-3258-4104-ace3-2bca6550197a`. No SQL, Agent 365 blueprint, runtime,
Service Bus queue/outbox, registration, canary, key, or Purview mutation occurred.

That state and its accepted snapshot are preserved because durable evidence cannot
be mixed with a new source fingerprint. Commit
`9b229434f4578a68fc8c60029838d30e133a1b93` fixes empty-tag discovery and changes
durable `RunQueued` reconciliation to exact GA `acr task show-run --run-id`
readback; unknown `IntentRecorded` outcomes remain no-resubmit. The next live action
at that checkpoint was distinct project `a365gw3` and resource group
`rg-a365-custom-gw-phase6b` in the same disposable target.

The `a365gw3` Plan
`sha256:16bcceb1a065ed2ab7b4fa86ae668048c3e79aca9cd7927e1c4a564d22724eaf`
bound source `sha256:8262d7a88aea42b2032e8f512c32864762129f9531ccaa0d0fef464c81a0e05c`
and ownership `8be8e474-c48d-43d0-9470-69b28659df4a`; authenticated What-If again
reported six Creates and zero Deletes. Apply completed provider/foundation/API
identity steps and reached 5/19. It persisted API build intent
`34d63927-4d89-44a5-a4b2-34eddac8cb6a`, then submitted exactly one ACR run before
rejecting the provider result: `az acr build` returned service run type `QuickRun`
while the accepted source required `QuickBuild`. No `RunQueued` claim was persisted
and no second build was submitted.

Exact readback showed run `de1` was the only ACR run and later succeeded as
`QuickRun`, producing only `gateway-api` digest
`sha256:6b7bec7ac533440f39ae5826c6b7829458e3af315dcddd259e1b3de835a4a829`.
No worker/Admin UI build, SQL, Agent 365 blueprint, runtime, Service Bus
queue/outbox, registration, canary, key, or Purview mutation occurred. The
`a365gw3` state, accepted snapshot, resource group, successful image, and Entra
application remain preserved and cannot consume changed source.

Commit `00018600b8b1bdd466f16ab28a66b58348b82a0b` aligns submission, exact-tag
discovery, exact run-ID polling, and final image verification to the one exact
`QuickRun` contract; it rejects `QuickBuild`, `AutoBuild`, and `AutoRun` without
provider-body disclosure.

The resulting isolated deployment `a365gw4-dev` used resource group
`rg-a365-custom-gw-phase6c`, ownership
`ced0c22f-ba7a-491c-8c25-38d76a55e7a8`, and registry
`acra365gw4dev6hdqn4`, exclusively in disposable target subscription
`internal-security-lab-02` (`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`). Its initial
accepted Plan
`sha256:21efe30b101e5092bb03d8547d50f08af88c0fcc6e138fbae69ead5d59d7c626`
bound configuration
`sha256:a45df6a92e10fe39c1bb5330b76c5f210c62aaba0175e627353d680c68e16cdb`
and source
`sha256:e13454d6d3258d8a6ac216c1bf7b92c237fc8fd1ec34bdbdff7a95b9aeac3af9`.
Authenticated What-If reported exactly six Deploy actions and zero Delete actions.

Apply completed 5/19 and stopped in `Immutable workload images` after persisting
API build intent `30bac341-4ef9-414b-bce1-499bb9efda8d`. At this checkpoint the
failure was interpreted as a sparse `az acr build --no-wait` scheduling receipt
being validated as a full run record before `RunQueued`; the later `a365gw6`
investigation below supersedes that interpretation. Exact readback showed run `de1`
succeeded as `QuickRun`, producing `gateway-api` digest
`sha256:3c65a6903a5cb3b95ee314d7bf495d4675ee777fb4816747e6e651e4fa327980`.

A fresh Resume Plan
`sha256:5caa84429699de696f9e3bb305913933158aa6683ab0209bfd380331e4611aa0`
bound the same configuration, source, ownership, and six-Deploy/zero-Delete
contract. Resume exactly recovered and digest-checkpointed the API image, persisted
worker intent `bafe753a-62e0-4f2d-8f59-69d75053b58c`, submitted exactly one worker
build, and stopped on the same then-unresolved submission-result defect. Exact run `de2` later
succeeded as `QuickRun`, producing `gateway-worker` digest
`sha256:6d5743b68ed84d8a6016c8b66d18caea0481cfe764aeb27d48a77836b77bb3d0`.
State remains API `DigestCheckpointed` and worker `IntentRecorded`; it does not
claim the worker run or digest as a durable bootstrap checkpoint.

No Admin UI build, SQL initialization, Agent 365 blueprint, runtime, Service Bus
queue/outbox, registration, canary, Gateway-key issuance or revocation, or Purview
action occurred. Preserve the accepted snapshots, state, resource group, Entra
objects, and successful images; do not Resume this generation with edited source.
Commit `3ad90d764bbd64acc778c24b0b09c0ff02be564e` now accepts only the exact
one-property run-ID scheduling receipt, persists `RunQueued` before polling, and
validates `QuickRun` plus output only through exact `show-run` readback. Focused ACR
tests pass 21/21; the complete Bootstrap suite passes 230 with zero failures and one
pre-existing macOS skip. Both changed PowerShell files parse, `git diff --check`
passes, and independent review found no P0/P1/P2 issue. The next live action is
fresh isolated project `a365gw5` in absent resource group
`rg-a365-custom-gw-phase6d`; do not Resume `a365gw4` with changed source. Existing
deployment subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated, and its
retained queues/messages were not accessed.

Fresh generation `a365gw5-dev` then started from absent resource group
`rg-a365-custom-gw-phase6d` and absent bootstrap state in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Ownership is
`06bba549-69ba-474b-97e7-100cdc31a4fa`; ACR is `acra365gw5devtn2ykh`.
Its accepted Plan
`sha256:ffc845dc08b140faf9e81362de3fc22d6cfab74000fd119f5a80e9cd19faaa98`
bound configuration
`sha256:40da086f6562c28b29a1c7a414ab3f35e806ef5b85c88693761208be2c6a509e`
and source
`sha256:2936dcb8ad1d742304a571717f0c7d48ae2c4d54074725fc5244a2043e7ad493`;
authenticated What-If reported exactly six Create actions and zero Delete actions.

Apply completed 5/19, persisted API intent
`396d698d-2968-4714-956a-cf8be964e9c8`, submitted exactly one API build, and
stopped before the `RunQueued` checkpoint. Exact run `de1` succeeded as `QuickRun`,
producing `gateway-api` digest
`sha256:375361ec21424dbb038c409ea018b96e0cc34c9e2926ee81803429e95b361fdd`;
bootstrap evidence remains `IntentRecorded`. Commit
`3ad90d764bbd64acc778c24b0b09c0ff02be564e` had introduced a run-ID-only
projection based on the then-current receipt hypothesis. This run proved only that
the shared command runner merged the queued-build stderr notice into the value
being parsed; `a365gw6` later proved that Azure CLI returns no result object or JSON
stdout at all for this `--no-wait` command.

No worker or Admin UI build, SQL initialization, Agent 365 blueprint, runtime,
Service Bus queue/outbox, registration, canary, Gateway-key action, or Purview
action occurred. Preserve this generation and do not Resume it with edited source.
Commit `a165519df704fdeb30dae7092f8f88cd4a89b22f` adds an explicit stdout-only
receipt-capture boundary that discards stderr without disk persistence, preserves
fixed redacted exit-code handling even when native error promotion is enabled, and
was used by exactly the presumed ACR no-wait scheduling receipt. Focused tests pass 87/87;
the complete Bootstrap suite passes 234 with zero failures and one pre-existing
macOS skip. All four changed PowerShell files parse, `git diff --check` passes, and
independent review found no remaining issue. The existing deployment subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` remains unselected and unmodified, and its
retained queues/messages were not accessed. The next live action is fresh isolated
project `a365gw6` in absent resource group `rg-a365-custom-gw-phase6e`.

Fresh generation `a365gw6-dev` started from an absent resource group and absent
bootstrap state in only target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Resource group is
`rg-a365-custom-gw-phase6e`, ownership is
`b354e365-48f9-4255-bb98-4f6222e192e7`, and ACR is
`acra365gw6devkgafft`. Its initial accepted Plan
`sha256:462a3cf947f0bd3be3a03f9ad7ed71e94f0a2c2aa629c68db021e30c09ed07cf`
bound configuration
`sha256:cc58aa76fd5b1bfd2556ae19a9e0df61f4f9ee862f189986b105814b2169f85e`
and source
`sha256:93dbe20bb0dcf061fb6f01fe07b4d9eef73fb146578fb5c4dc3db80ee591ccfe`;
authenticated What-If reported exactly six Create actions and zero Delete actions.
Foundation and Gateway API identity completed.

The first API image attempt recorded intent
`9c351f63-7b39-4d83-8d26-05ade97264fb` and submitted exactly one build, but again
stopped before `RunQueued`. Exact investigation proved the remaining contract:
Azure CLI 2.89.1 deliberately replaces the command result with null whenever a
`supports_no_wait` command is invoked with `--no-wait`. The build is scheduled,
but neither stdout-only JSON nor a sparse result object can exist; the queued-build
notice is only diagnostic stderr. Exact API run `de1` succeeded as `QuickRun` with
digest
`sha256:2cf9d8f03d4d5b9ac3fbb14265f526229b2927e990109cbacdc72ca773d47cbb`.

The post-foundation Resume Plan was
`sha256:da4bb058ab387b4ac1736abb2d109c4d376bbb0fef93bb808447001d266b599e`
with unchanged configuration, source, ownership, six Deploy actions, and zero
Delete actions. Exact intent-tag recovery bound and digest-checkpointed `de1`
without resubmission, then submitted one worker run. A later Resume recovered
worker run `de2` and submitted one Admin UI run; the final Resume recovered `de3`
and completed `Immutable workload images`. All three runs are succeeded
`QuickRun`s and there are exactly three: API digest above, worker digest
`sha256:3f8ffaa95b0546090c5e49987899001657bccd1f25a15edeef5263200698f2e1`,
and Admin UI digest
`sha256:da6f12c8383bc5be015157b11ff88ba65d3aba476975650824eadcfbd3236b45`.
This is live proof that the unique pre-mutation intent prevents duplicate builds
and supports exact recovery, not proof that the impossible CLI receipt contract is
correct.

Bootstrap then stopped safely at **6/19** in `Inert identity deployment` before an
ARM group deployment was recorded. Both intended Container Apps still read back
absent. The exact local blocker set is PowerShell parameter binding: the inert call
intentionally passes an empty worker principal and no `managerApplications`, while
`Deploy-GatewayCore` declared both inputs mandatory without allowing the initial
empty values. Direct checks reproduced `ParameterBindingValidationException` for
each input independently; no ARM, SQL, Agent 365 blueprint,
workflow identity, Service Bus queue/outbox, runtime, Admin UI, registration,
canary, Gateway-key, or Purview action followed. Preserve `a365gw6`, its three
images, accepted snapshots, foundation, API identity, and failed step evidence; do
not Resume it with edited source. The next action is to replace the impossible ACR
receipt assumption with one-submit bounded exact-tag discovery, permit only those
intentional initial empty identity inputs at binding while keeping runtime strict,
run the complete local gate, and
start a new isolated generation. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was never selected or mutated, and its
queues/messages were not accessed.

Commit `715bbf93dcefa95266f1ce7616f8d39ca137fa10` is the corrected source for the
next isolated generation. It replaces the impossible `--no-wait` receipt contract
with one stdout-isolated, synchronous `az acr build --no-logs` completed-`QuickRun`
projection, followed by exact run-ID and immutable tag/digest readback. The
pre-mutation intent remains durable; recovery scans registry-wide for only its
unique output tag, requests a 101st truncation sentinel, and never resubmits an
unknown recovered outcome. Initial deployment permits only the intentional empty
worker and manager-authority inputs and rejects every runtime-only database,
activation, Purview, and Admin UI input before Azure access. Runtime worker
authority must exactly match the ownership/source-bound database-attestation
object ID.

The correction also maps ARM `agent365RegistryProvider` to evidence
`registryProvider`, uses named hashtable splatting for the final preflight, and
preserves `managerApplications` as a string array. Continuous development is
explicitly mutually exclusive with every exact-bound flag/value. Registry and
admission readback requires one plain-value setting in exactly one container and
rejects case-conflicting duplicates, missing values, and secret references; exact
registration and delegated-action windows are verified as independent states.
The full local gate and independent review are recorded above. No Azure, Entra,
SQL, Agent 365, Service Bus, Registry, Purview, registration, key, or canary
mutation was performed by this correction. The next live action is a fresh
`a365gw7` Plan in absent resource group `rg-a365-custom-gw-phase6f`, only in target
subscription `6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Preserve every earlier
generation, and keep protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` completely outside the proof.

## 2026-08-29 local Phase 0–6 bootstrap candidate (unreleased and incomplete)

The working tree now exposes the day-zero path through `./gateway` on macOS/Linux
and `gateway.cmd` on Windows. `gateway setup` is an ephemeral loopback-only Fluent
UI and `gateway up` is the terminal workflow; both call the same PowerShell state
machine. This is local source only. It has not been applied to this development
resource group or to a disposable subscription.

This checkpoint does **not** complete the original Phase 0–6 plan. Phase 0 remains
partial pending every-checkpoint interruption proof and a disposable deployment;
Phase 1 is source-complete but lacks the required platform evidence; Phases 2–4
retain guided-profile, preflight, and per-error recovery-contract gaps; Phase 5 is
implemented locally but not deployed/authenticated; and Phase 6 clean-subscription,
interrupt/Resume, first-registration, and bounded-canary proof has not run. The
canonical per-phase matrix is in `docs/implementation-status.md`.

Plan now fingerprints the configuration, deployment descriptor, sanitized ARM
What-If, deployment-affecting source, and one public client IPv4 corroborated by
bounded ipify and AWS Check IP reads. Acceptance creates an ignored,
content-addressed source snapshot. Apply/Resume requires the running checkout to
match that source, validates the snapshot, and executes mutation modules, templates,
scripts, project inputs, and the allowlisted ACR build context from the accepted
bytes. Any durable step or output prevents another source generation from being
mixed into the same state.

Azure operations are pinned to the exact reviewed subscription and authenticated
tenant. A fresh deployment refuses a pre-existing resource group or same-name
workload identity. Bootstrap deployments/resources carry the random state ownership
ID and accepted source fingerprint; API, worker, and Admin UI checkpoints also
require exact immutable image references before reuse.

Empty-database setup may open only the Plan-disclosed exact caller-IPv4 firewall
rule. It proves that rule absent after use and restores/proves SQL public access
`Disabled`; failed cleanup preserves the safe ignored recovery record. The migrator
accepts only zero user tables and verifies the exact EF schema plus narrowly bounded
managed-identity database authority.

The Admin UI user-assigned identity receives Key Vault Secrets User only on its
exact Entra client-secret resource. The worker's optional Purview certificate role
uses the exact configured certificate-secret scope, not the shared vault, and the
API has no shared-vault role. Readback rejects wider/extra assignments.

The full post-hardening local gate passes: zero-warning/zero-error Release build;
**1,279/1,279** direct Release tests (unit 478, Admin UI 155, local Setup 75,
observability/runtime 149, integration 92, end-to-end 106, architecture 113, and
security 111); Pester 208 passed, 0 failed, and 1 Windows-only launcher test skipped
out of 209 discovered; **16** PowerShell files and **2** bootstrap JSON contracts
parsed; all **23** Bicep templates compiled; `dotnet format --verify-no-changes`
and `git diff --check` clean; and **58** repository-local links across **55**
Markdown files with no broken target. A responsive loopback Setup UI check at
1280x720 and 390x844 showed no horizontal overflow and confirmed that an unsafe
existing ignored configuration disables Start without overwriting the file. These
are local source results only; do not substitute them for the live Prompt Shields
deployment evidence below.

## 2026-08-29 live Prompt Shields deployment and proof

The external development environment now runs the pre-model prompt-protection
contract. This deployment did not create, retry, inspect, settle, or dispose any
historical Registry or Service Bus failure artifact.

- Target is subscription `95bedc30-f6ac-481b-a3a6-588d2883c216`, resource group
  `rg-agent-gateway`. Final source verification is a zero-warning/error Release
  build; **1,121/1,121** tests; clean `dotnet format`; PowerShell **18/18**;
  Bicep **23/23** templates and **5/5** parameter files; and zero broken local
  documentation links across 54 Markdown files.
- Migration execution ran inside `cae-a365gw-dev-vnet` because Azure Policy keeps
  SQL public network access disabled. One-time job
  `job-gw-db-migrate-20260829-d8db90y` applied the complete Prepare set twice,
  including `20260829_purview_policy_profiles.sql` and
  `20260829_prompt_protection.sql`. SQL Entra administrator ownership was restored
  immediately; the job was deleted and SQL public access remains disabled.
- Azure AI Content Safety account `cs-a365gw-dev-s4a3t2` is S0 in Korea Central,
  has local authentication disabled, and exposes
  `https://cs-a365gw-dev-s4a3t2.cognitiveservices.azure.com/`. API managed identity
  `11c2b9f3-1845-4fe2-82da-70b91c5abca7` has Cognitive Services User only at that
  account scope.
- API revision `ca-gateway-api-dev--ps-20260829-0239` is latest and ready on
  `sha256:4b592efec95c6b3e415953ca3874f7863498d3e834e72b50d0c7162682fe8906`.
  Admin revision `ca-gateway-admin-dev--ps-20260829-0241` is latest and ready on
  `sha256:06ee96a84962440fdede9f381c4d0ca18b84f9bcfd34a46d98f7259b77a248aa`.
  Both `/health` endpoints returned HTTP 200.
- Gateway default Prompt Shields and registration
  `ca5de6e3-d30a-4c57-8085-7382cc69fa0a` Prompt Shields are enabled. The selected
  registration maps external ID `agent-9bf5e884c3f84d33af4d9fc72cd0dad9`, child
  Agent ID `54bec58b-bf56-4a98-928a-318194686cc9`, blueprint
  `99d9ac9a-7656-4088-b695-066457988735`, and Registry ID
  `c27a612a-26a9-4460-a2e5-4fafaa5dd6dc`.
- Disposable canary execution `job-gw-live-canary-20260829-mk14ghs` proved an
  allowed prompt with Prompt Shields `Allowed` and Purview `AuditLogged`, activity/
  OTel HTTP 202, receipt-bound interaction HTTP 202, and an injection prompt blocked
  with HTTP 403 `PROMPT_BLOCKED_BY_PROMPT_SHIELD`. Safe correlations are
  `ce1d7832-6fa9-463f-b41c-53af013aa0a4`,
  `1d116dc0-bfcc-4eff-8f15-ababe7f650cb`,
  `759e4244-5475-4b19-9221-319ba8cca92a`, and
  `b05a3b95-b4e8-4e80-a4e1-0f245ff506cb`.
- The canary held its one-time credential only in memory and revoked safe key ID
  `7a275a31-7204-466a-9a1a-a37590a2ff4a`. Its temporary Gateway Administrator app
  role, Container Apps job, and system service principal were removed. The live
  agent page shows Prompt Evaluation Allowed, Prompt Evaluation Blocked, Activity
  Submitted, Interaction Submitted, and the revoked key lifecycle entry.
- Post-canary queues drained to v3 `0/0/10`, retained v2 `0/0/3`, and historical
  v1 `0/0/2`. No DLQ was opened or disposed; the additional v3 retained item is not
  assigned a cause without a separately authorized evidence review.

This proves the external development path, not a supported production offering.
The Agent 365 Registry dependency remains beta/preview and Microsoft does not
support it for production use. Staging multi-replica, provider-outage, failover,
capacity, backup, privilege, and incident-readiness gates remain outstanding.

## 2026-08-29 source-only repository checkpoint (superseded by live proof above)

The clean-subscription bootstrap, repository cleanup, API/Admin UI hardening, and
documentation convergence were validated locally without an Azure, SQL, Entra,
Service Bus, Graph, Registry, Purview, or deployment mutation. The deployed
revisions, digests, registrations, policy, queue counts, and SQL evidence in this
document therefore remain unchanged.

Validation at this source checkpoint is:

- zero-warning/zero-error Release builds for the solution and DatabaseMigrator;
- **1,121/1,121** direct Release tests: unit 409, Admin UI 151, end-to-end 106,
  security 111, observability/runtime 144, integration 92, architecture 108;
- `dotnet format --verify-no-changes` clean;
- PowerShell parsing **18/18**, Bicep templates **23/23**, and parameter files
  **5/5**;
- a successful non-mutating bootstrap `Plan` through all 12 phases;
- **52** Markdown files with **43** repository-local links and zero broken targets,
  plus **8** parseable non-evidence JSON files; and
- **15** matching Claude/Codex agent roles and three byte-identical shared skills.

The cleanup removed only files with no current build, runtime, deployment, test, or
documentation consumer: the 159.83 MB bundled Python runtime, unused Bootstrap
template assets, root build/restore transcripts, rendered Container App YAML, and
obsolete local launch wrappers. Operational evidence and incident records remain.
Correlation IDs, Problem Details, typed client diagnostics, and script failures now
log bounded safe metadata without dependency bodies or raw exception messages. The
Admin UI adds accessible focus/skip behavior, clearer navigation and result states,
an explicit registration step navigator, and actionable admission guidance.

A subsequent source-only relocational refactor removed the ambiguous `deploy/`
tree: declarative Bicep and SQL now live under `infrastructure/`, while reviewed
existing-environment deployment, preflight, canary, and recovery scripts live under
`operations/`. `bootstrap/` remains the sole clean-subscription orchestration entry
point. All workflows, bootstrap modules, migrator paths, architecture tests,
runbooks, and Claude/Codex deployment instructions were synchronized. Validation
remains zero-warning/error with **1,121/1,121** tests, PowerShell **18/18**, Bicep
templates **23/23**, parameters **5/5**, and `dotnet format` clean. Documentation is
now **54** Markdown files and **51** repository-local links with zero broken targets.
No live resource, revision, queue, registration, policy, or SQL state changed.

The source increment later deployed in the live checkpoint above adds optional Azure AI Content Safety Prompt
Shields and a prompt-only Purview pre-model endpoint. Allowed evaluations issue a
short-lived, single-use salted-hash-bound receipt required by protected completed
interactions; blocked evaluations return safe RFC 9457 client details. Admin UI,
sample client, OpenAPI, additive SQL migration, managed-identity Content Safety
Bicep/bootstrap wiring, and focused allow/block/replay tests are synchronized. The
complete gate is the 1,121-test/static total above. At the time of this historical
checkpoint no prompt-protection migration or Azure state had changed; the newer
live section above supersedes that deployment status.

An authenticated visual browser pass was not available in this local checkpoint:
the in-app browser had no signed-in tenant session, and the local UI correctly
refused startup without its required Gateway API URL/scopes. UI behavior is covered
by the passing 151-test bUnit project. At this historical checkpoint those changes
were not deployed; the live Prompt Shields section above now supplies the later
digest/revision and authenticated-route evidence. A disposable clean-subscription bootstrap `Apply` also remains the next
recovery proof; the successful local `Plan` is not live deployment evidence.

## Current disposition

Development has the reviewed **workflow-v3** API, worker, Admin UI, v3 queue,
delegated Registry grant, API-app OBO FIC, worker eight-role allowlist, and
queue-scoped worker Sender role deployed. At least these two continuous
registrations have independently captured Active evidence:

- create-new registration `fb35a5ce-8df5-48c2-86e9-9411d17df070`, external ID
  `agent-89a205c4340644debaf53248cfdfd8eb`, blueprint
  `79a71594-6435-4c64-a7bf-5f472a475792`, child
  `640f3b3a-1ff2-4ab5-b1a4-cfac59dd35de`, Registry
  `9451d70c-71b6-45eb-9db5-4be8f05c6d04`, completed retry operation
  `6395ab47-e6c8-4584-8867-36c5c09f9475`, safe active key ID
  `b3abe5d0-7181-45aa-beb5-2dddba328f08`; and
- reusable-blueprint registration `ff685604-999c-4584-9cec-87ec21f870ee`, external
  ID `agent-ef6f55ea1525406bb93997c2e8b771cd`, blueprint
  `29fa5cc5-c42b-4bdc-8f99-d85a5b91ad01`, child
  `954fec63-53a7-4556-abaa-67acf11956c8`, Registry
  `b2bf22e4-3d2c-49b4-8ead-a003d2496dab`, completed operation
  `099248a5-e1a3-4c50-a456-d0a04a6f1933`, safe active key ID
  `ac74e01b-a7ec-4cb6-93d7-59c0cdfb7fbb`.

Both rows are visible and Available on platform `A365CustomGateway`. The newest
portal usage counters remain zero immediately after submission and are treated as
delayed aggregation, not transport proof. Direct requests returned HTTP 202 and the
v3 queue drained.

A later user-run external-browser create-new registration was reported successful,
but its safe identifiers and a post-run SQL/queue snapshot were not independently
captured here. Do not infer a current total registration, catalog, job, or queue
count from the two fully evidenced rows above.

Purview policy `A365 Tourist OBO Python DLP (OBS Gateway)` targets the reusable
blueprint with `EnforcementPlanes Application`. Benign correlation
`de14f217-3380-42cb-9b9e-92df5a2e9ea7` returned `AuditLogged`; synthetic sensitive
correlation `0c882b36-efe9-444e-bf86-d1b4415ea455` returned `Blocked` and queued no
observability. `uploadText` is inline; `downloadText` is offline. The protected
application location is the blueprint client ID, not the Gateway API app or child.

Three bounded v2 failures and three v2 DLQ messages remain immutable evidence. The
second created one reconciled reusable Gateway FIC. The third reused that FIC,
created child Agent ID `8e4859bd-477c-4133-adb1-9030ec13bf5c`, assigned OtelWrite,
then received HTTP 500 from its one application-authenticated Registry POST without
a durable ID. That historical outcome remains unknown and separate from v3. Never
retry, attach, replay, settle, purge, or delete that registration, message, FIC,
child, or role assignment.

Development explicitly enables continuous admission/action and disables exact
binding. The signed-in Administrator UI automatically invokes each required Registry
action once. Staging/production remain closed by default and use independent exact-
bound windows. Continuous development retains all identity, OBO, locking, durable
intent, and one-POST checks.

No historical retry, second Registry POST, retained-artifact mutation, production
work, destructive cleanup, message disposition, credential disclosure, or SQL
finalization is implied. The current local source totals are recorded in the
implementation status; the separate live-deployment totals above remain the
deployed evidence boundary.

Historical note: the first live `OpenDelegatedCompletion` exposed a controller
`Nullable<Guid>.Value` bug before user action. The fix plus architecture regression
coverage passes focused architecture 105/105 and PowerShell parser 19/19. The full
1,086/1,086 test-project gate and zero-warning/error Release build passed at that
checkpoint. The current complete gate is in the implementation status.

## Effective development resources

| Resource | Verified state |
|---|---|
| Subscription | `95bedc30-f6ac-481b-a3a6-588d2883c216` |
| Resource group | `rg-agent-gateway` |
| API | `ca-gateway-api-dev`, digest `acra365gwdevs4a3t2.azurecr.io/gateway-api@sha256:5275b3adcdb3e17f39e7b7466fc989bfeae04904f64f85226931be19c6e939b7`; healthy revision `ca-gateway-api-dev--purviewguard-20260828222324` |
| Admin UI | `ca-gateway-admin-dev`, digest `acra365gwdevs4a3t2.azurecr.io/gateway-admin-ui@sha256:8a447f481294822141d550b9313c2bd3249dc1fea7430cefcc21f2a2ef1c876e`; healthy revision `ca-gateway-admin-dev--continuous-202608282042` |
| Workflow-v3 worker | `ca-gateway-worker-dev-vnet`, digest `acra365gwdevs4a3t2.azurecr.io/gateway-worker@sha256:9dad873fe49b17c55677674688616c9770f8e3810c878702011632dda9dd7c9e`; healthy continuous revision `ca-gateway-worker-dev-vnet--rbacrefresh-202608282058` |
| Historical worker | `ca-gateway-worker-dev`; preserved on workflow-v1 queue and not a v2 receiver |
| Workflow-v3 queue | `gateway-provisioning-v3`, Active, active 0 / scheduled 0 / DLQ 9 |
| Retained workflow-v2 queue | `gateway-provisioning-v2`, active 0 / scheduled 0 / DLQ 3 |
| Historical queue | `gateway-provisioning`, active 0 / scheduled 0 / DLQ 2 |
| SQL | `sql-a365gw-dev.database.windows.net / GatewayDb`; Entra-only administration |

The API and worker run the SQL-claimed outbox relay required for initial and
continuation messages; the worker has queue-scoped Sender and Receiver only.
Retained v2/v1 messages remain isolated; no worker generation may receive from
another generation's queue.

## SQL and recovery checkpoint

The newest exact SQL artifact is still
`live-state-20260828-v3-success-final.json` from before the two continuous canaries.
It remains valid historical/recovery evidence, but its v3 job and outbox totals are
not current and must not be copied into a new activation decision. Current live
queue evidence is recorded above; capture a fresh zero-script verifier artifact
before any SQL-sensitive rollout or finalization.

The reviewed pre-cutover SQL path and current recovery gate are verified:

- `artifacts/deployment-evidence/live-prepare-20260824.json` remains the immutable
  prepare provenance. It is phase `prepare`, repeat two, contains the exact current
  SHA-256 hashes of the four reviewed SQL scripts, and proves workflow v2 ready with
  one legacy global idempotency index. Do not rerun live DDL merely for timestamp
  freshness.
- A new separate copy, `GatewayDb-v2-recovery-20260826025402`, is retained. The first
  attempt to verify its baseline with the worker identity failed before any schema
  action because of inherited contained-user state; the worker was restored to its
  inert runtime revision before continuing.
- `artifacts/deployment-evidence/recovery-baseline-20260826.json`, verified through
  the API identity at `2026-08-26T03:01:23.76017Z`, identifies that distinct copy and
  proves the pre-upgrade boundary: phase `baseline`, repeat one, zero scripts,
  workflow v2 false, and one legacy global index.
- `artifacts/deployment-evidence/live-state-20260826.json`, captured read-only at
  `2026-08-26T03:06:13.3306396Z`, is phase `verify`, repeat one, and zero scripts. It
  proves live `GatewayDb` has workflow v2 ready, one legacy global index, zero
  publishable outbox messages, two workflow-v2 jobs, and two legacy jobs.
- `artifacts/deployment-evidence/live-state-20260826-arm-preflight.json`, captured
  read-only at `2026-08-26T03:40:03.8854162Z`, is the immutable evidence used by the
  completed `WhatIf`/`Arm`. It is phase `verify`, repeat one, contains zero scripts,
  and proves the same schema, outbox-zero, and jobs-two-plus-two state. It will age
  beyond the short outbox window and must be regenerated before another `Arm`.
- `artifacts/deployment-evidence/live-state-20260826-canary.json`, captured read-only
  at `2026-08-26T07:11:03.2622069Z`, is the phase-`verify`, repeat-one, zero-script
  proof used for the submitted canary. It proves workflow v2 ready, legacy index
  one, outbox zero, workflow-v2 jobs two, and legacy jobs two.
- `artifacts/deployment-evidence/live-state-20260827-v3-canary-0841.json`, captured
  read-only at `2026-08-27T08:41:38.2934168Z`, is an earlier phase-`verify`,
  repeat-one, zero-script proof. It proves outbox zero, active workflow-v3 jobs zero,
  awaiting workflow-v3 jobs zero, active workflow-v2 jobs three, and legacy jobs
  two. Its separate 60-minute controller freshness limit covered the two latest
  no-submission windows and has now expired; regenerate it before another Arm.
- `artifacts/deployment-evidence/live-state-20260827-v3-canary-0949.json`, captured
  read-only at `2026-08-27T09:49:10.6200517Z`, is an earlier phase-`verify`,
  repeat-one, zero-script proof. It proves outbox zero, active workflow-v3 jobs zero,
  awaiting workflow-v3 jobs zero, active workflow-v2 jobs three, and legacy jobs
  two. Its 60-minute controller freshness limit guarded the fourth no-submission
  window.
- `artifacts/deployment-evidence/live-state-20260827-v3-canary-1158.json`, verified
  at `2026-08-27T11:58:17.1952233Z`, was the fresh evidence accepted for the
  successful registration Arm. It is historical/stale after registration created a
  job and changed live SQL state; never reuse it for delegated completion.
- `artifacts/deployment-evidence/live-state-20260828-v3-completion-20260827223521.json`,
  verified at `2026-08-27T22:35:53.5652147Z`, was the fresh zero-script read-only
  proof used for the final exact-operation completion window. It proves outbox zero,
  active v3 jobs one, awaiting-administrator v3 jobs one, v2 jobs three, and legacy
  jobs two.
- `artifacts/deployment-evidence/live-state-20260828-v3-post-completion.json`,
  verified at `2026-08-27T23:03:32.2714306Z`, is the post-action zero-script
  read-only snapshot. It proves outbox zero, active v3 jobs one,
  awaiting-administrator v3 jobs zero, v2 jobs three, and legacy jobs two. The
  active v3 count is the non-completed manual-intervention job; it is not queued
  work and does not authorize retry.
- `artifacts/deployment-evidence/live-state-20260828-v3-success-final.json`, verified
  at `2026-08-28T09:01:17.134703Z`, is a historical zero-script read-only snapshot.
  It proves workflow-v2 ready, legacy index one, publishable outbox zero, active/
  manual v3 history eight, awaiting-administrator v3 zero, v2 three, and legacy two.
  It was captured after the final successful telemetry export and before restoring
  the worker to its sole inert runtime revision.
- SQL public network access remains policy-enforced `Disabled`.
- `20260825_scoped_idempotency_finalize.sql` remains **unapplied**.

These artifacts prove only their recorded points in time. The latest SQL artifact
predates the continuous registrations and was paired then with queue baselines v3
`0/0/8`, v2 `0/0/3`, and historical `0/0/2`; the current independently captured
queue checkpoint is in Current disposition. Capture new SQL evidence before any
SQL-sensitive action.

Finalization remains a separate reviewed migration decision and is still unapplied.

### Reproducible private live-state verification

The approved workflow-v3 private verifier image used for the latest evidence was
`acra365gwdevs4a3t2.azurecr.io/gateway-db-migrator@sha256:931c8db13dac2e341e916dd638d497180643c15d8f6e8fe1610cf36a9a953dd8`.
It ran temporarily on the inert VNet worker with managed identity and only the
non-secret `DATABASE_MIGRATOR_*` inputs required for server/database, phase
`verify`, repeat `1`, `DATABASE_MIGRATOR_EVIDENCE` for the evidence-file path,
stay-alive, and
`DATABASE_MIGRATOR_REPOSITORY_ROOT=/repo`. Phase `verify` is zero-script/read-only.
Earlier attempts omitted the repository-root setting, failed before SQL access, and
restored the worker inert; they are not database verification evidence.

Do not use `DATABASE_MIGRATOR_EVIDENCE_FILE`: the migrator maps `--evidence` to
`DATABASE_MIGRATOR_EVIDENCE`. A temporary fourth-window verifier revision used the
wrong `_FILE` name, completed the same zero-script read-only verification but wrote
no artifact, and was replaced by the corrected `0949` run before the runtime worker
was restored clean and inert.

Retrieve the evidence through Azure exec using a command that emits wrapped
base64-only lines, concatenate only those payload lines, and decode locally. Do not
stream plain JSON: Azure exec can concatenate the WebSocket-close trailer to the
JSON and make the captured artifact invalid.

After retrieval, restore the reviewed worker runtime image and remove **every**
`DATABASE_MIGRATOR_*` environment setting. Read back the exact runtime digest,
absence of command/argument overrides and migrator settings, all processing/
provisioning/Registry/relay gates false, and expected inert scale. Do not treat the
verification as complete until that clean runtime state is proved.

## Identity, role, and provider checkpoint

- The API managed identity has the typed-catalog role
  `AgentIdentityBlueprint.Read.All`.
- The deployed workflow-v3 worker has the exact eight-role Graph application
  allowlist and no Registry application role. The retained historical worker was
  not changed.
- The Gateway API app has exactly the admin-consented delegated Graph scopes
  `AgentRegistration.ReadWrite.All` and `AgentRegistration.Read.All`, with the grant
  read back for `AllPrincipals`. Exactly one API-app FIC was verified for managed-
  identity signed assertions: tenant v2 issuer, API Container App managed-identity
  principal subject, and sole audience `api://AzureADTokenExchange`.
- The Agent 365 resource publishes `Agent365.Observability.OtelWrite`.
- The reviewed development `managerApplications` input was correlated from A365
  CLI `1.1.214+90c444832f` and tenant inventory to verified Microsoft 365 App
  Catalog Services. It is tenant/provider configuration, not a universal constant.
- Signing in as Global Administrator does not substitute for backend application
  roles or delegated admin consent. The workflow-v3 Registry endpoint separately
  requires an authenticated Gateway Administrator user with `oid` and
  `access_as_user`; app-only callers are rejected.
- Global Purview is true. All three Graph roles remain present and tenant licensing
  is user-confirmed. The reusable-blueprint registration is Enforce: its blueprint
  application location returns inline `uploadText` and offline `downloadText`, with
  live benign-audit and synthetic-block proof.

The last independently captured authenticated typed catalog contained 12 blueprints:
7 compatible/selectable and 5 incompatible/disabled. A later user-run create-new
flow was reported successful, so recapture the catalog before treating those counts
as current. An earlier 11-row property snapshot found equal `id`/`appId` values on
every row then present; that finding does not establish later rows' values.

## Purview live proof and remaining boundary

The first AuditOnly attempt exposed two code defects without changing provisioning
or Registry state: the documented content-activity shape does not accept the
conversation `agents` collection, and raw Graph error bodies were intentionally
unavailable in safe logs. Current source omits `agents` and content from AuditOnly
records, while Enforce continues to send child/blueprint `aiAgentInfo`. The Graph
client now records only a sanitized bounded `error.code`; it never logs the response
body or message.

The corrected bounded AuditOnly proof succeeded:

- mismatched external-ID activity was rejected with HTTP 403, correlation
  `35efb3b2-78e7-48d6-a614-c718f5c58781`;
- matched activity returned HTTP 202, correlation
  `65dcf0ad-9cb1-4cb9-8893-146035adad9d`;
- matched completed interaction returned HTTP 202, correlation
  `c83b48d3-30f5-4504-a939-08d06bd3f106`; and
- the interaction response is emitted only after both Graph content-activity POSTs
  return HTTP 201, proving prompt/response metadata acceptance without raw content.

At that earlier AuditOnly checkpoint, three publishable data-plane outbox messages existed after the diagnostic and
corrected calls. Worker revision `ca-gateway-worker-dev-vnet--tdrain-194240` was
narrowly enabled for processing with provisioning execution still false, drained
the v3 queue to zero active/scheduled, and was immediately superseded by inert
revision `ca-gateway-worker-dev-vnet--inert-194331`. That checkpoint's v3 queue was
`0/0/8`; the current state is recorded above.

The earlier Gateway-app and child-location probes are superseded identifier-model
experiments. The verified policy boundary is the reusable blueprint client ID. The
live policy uses `EnforcementPlanes Application`; `computeProtectionScopes` returns
inline `uploadText` and offline `downloadText`. API revision
`ca-gateway-api-dev--purviewguard-20260828222324` processes each activity according
to that returned mode. Benign content is accepted/audited, and the authorized
synthetic credit-card prompt is blocked before persistence/observability enqueue.
All diagnostic raw keys were overlap-rotated, verified, revoked, and cleared from
the browser runtime; only the safe active key IDs in Current disposition remain.

## Workflow-v3 registration and completion chronology

Fresh zero-script evidence
`artifacts/deployment-evidence/live-state-20260827-v3-canary-0713.json` passed before
activation. The first Arm attempt used the incorrect, nonexistent API digest
`sha256:de5866bf295db8fa7ba842f7e9b85217e744f4fe546ee149d0dd322ecb61b47b`
and failed at image pull before admission opened. Controller recovery could not
initially prove API closure because the bad revision never became ready. A separate
read-only inspection then proved both API gates false, the previous closed revision
still serving health 200, the worker inert, v3 `0/0/0`, retained v2 `0/0/3`, and no
new job or outbox work.

The guarded correction deployed the reviewed API digest closed as
`ca-gateway-api-dev--failclosedfix-0827163313`. Corrected WhatIf and Arm passed. One
five-minute registration window opened exact-bound only to
`agent-v3demo-20260827030009-3c870882`; it closed at
`2026-08-27T07:53:51.1109935Z` without a browser submission, Gateway registration,
job, key, Agent ID, Registry request, or other Microsoft mutation.

Newer zero-script evidence
`artifacts/deployment-evidence/live-state-20260827-v3-canary-0841.json`, verified at
`2026-08-27T08:41:38.2934168Z`, then passed corrected WhatIf and Arm. Two further
five-minute windows opened with the same exact external-ID binding and closed at
operator deadlines `2026-08-27T09:04:42.7746751Z` and
`2026-08-27T09:17:51.6770322Z`; their paired API-enforced crash deadlines were
`2026-08-27T09:07:18.6183349Z` and `2026-08-27T09:20:29.5525772Z`. Neither produced
a form submission, Gateway record,
job, one-time key, Agent ID, Registry request, or other Microsoft mutation; metadata-
only polling also observed no Service Bus count change. The live Admin UI was
refreshed during the final window, and
the form was verified with the reviewed external ID, `simple-echo-agent Blueprint`,
Agent 365 on, Azure Monitor off, and Purview off; the final submit button was left to
the user and was not clicked.

Fresh zero-script evidence
`artifacts/deployment-evidence/live-state-20260827-v3-canary-0949.json`, verified at
`2026-08-27T09:49:10.6200517Z`, then passed corrected WhatIf and Arm. A fourth
five-minute window opened with the same exact external-ID binding. Its operator
deadline was `2026-08-27T10:11:26.1449657Z` and its API-enforced crash deadline was
`2026-08-27T10:13:56.3860457Z`. The live form was prepared with display name
`axtstaa`, the reviewed external ID, `simple-echo-agent Blueprint`, Agent 365 on,
Azure Monitor off, and Purview off. The user did not click Register, so the window
produced no form submission, Gateway record, job, one-time key, Agent ID, Registry
request, or other Microsoft mutation. Independent read-only status at
`2026-08-27T10:24:17Z` again showed v3 `0/0/0`, retained v2 `0/0/3`, historical
`0/0/2`, a clean runtime worker template, and no residual migrator settings.

Fresh zero-script evidence
`artifacts/deployment-evidence/live-state-20260827-v3-canary-1158.json`, verified at
`2026-08-27T11:58:17.1952233Z`, passed WhatIf/Arm. The exact-bound registration
window succeeded and produced the current registration, operation, key metadata,
child, and 71% state recorded above. Registration admission then closed.

The first `OpenDelegatedCompletion` invocation failed on a controller
`Nullable<Guid>.Value` bug before any user action or Registry request. Recovery made
the API fail-closed and worker inert. A later re-Arm detected that `1158` was stale
after registration and stopped without mutation. A narrow manual exact-image worker
rearm used revision `ca-gateway-worker-dev-vnet--resume-124250` while preserving all
queue/message boundaries.

After the controller fix, two delegated-completion windows opened exact-bound to
operation `5c4ba41d-24e5-473c-9126-f89f37f7bb18`. Both closed without user action,
exact-operation API logs, Registry request, or final-stage enqueue. Their closed API
revisions were `ca-gateway-api-dev--delegatedclosed-20260827214632` and
`ca-gateway-api-dev--delegatedclosed-20260827220053`.

That Deactivate passed and was later superseded by the diagnostic sequence below.
The queue baselines remained v3 `0/0/0`, retained v2 `0/0/3`, and historical
`0/0/2`; this is safe recovery evidence, not Registry or telemetry completion.

Subsequent live completion diagnostics remained pre-POST and retry-safe. The first
action returned HTTP 403 because the API authorization assertion checked only `scp`,
while the production Microsoft Identity Web token exposed the documented mapped
scope claim URI. API digest
`sha256:c8b31058424470cbda01a5e3e1ca6c2d3243a2e13cd70e973dab7dc018dfe4e3`
deployed the dual-claim fix. The next exact action reached the handler but rejected
the verified prefix because it treated the opaque Graph app-role-assignment ID as a
GUID. Microsoft Graph documents both app-role-assignment and federated-credential
`id` as strings. Digest
`sha256:217b466a8820fd7479ceb0e75d88b0011002760fc0d144111bec8f3a7becfb74`
deployed bounded URL-safe string validation for those two resource IDs while
preserving GUID checks for actual object/client IDs. Neither action persisted POST
intent, issued a Registry POST, enqueued stage 7, or changed the 71% operation.

Two attempts to open the next exact-operation window then stopped during read-only
activation prerequisites: the operator-side `az rest` exact GET of retained FIC
`fea6b67c-008a-49aa-9672-6b98500d3d97` returned Unauthorized because the Azure CLI
session required reauthentication. This was not evidence that the retained FIC was
missing. Each attempt ran fail-closed recovery.

A clean interactive login then refreshed the existing administrator session without
adding consent. Exact GET matched the retained FIC. Fresh SQL evidence
`live-state-20260828-v3-completion-20260827223521.json` passed, the reviewed worker
was narrowly rearmed as `ca-gateway-worker-dev-vnet--resume-20260827223855`, and
full completion WhatIf passed. One controller window opened exact-bound only to
operation `5c4ba41d-24e5-473c-9126-f89f37f7bb18`; operator deadline was
`2026-08-27T22:54:36.6267911Z` and API crash deadline was
`2026-08-27T22:57:01.4389799Z`.

The signed-in Administrator clicked the confirmation action exactly once. The
Registry create boundary returned an ambiguous outcome before a durable Registry ID
was recorded. The operation persisted `RequiresManualIntervention` at 71%, failed
`RegisterAgent`, retained final verification pending, and emitted safe correlation
ID `208097d1-e8aa-442f-bd50-e533ec16137f`. The UI correctly states that the
operation is not replayable. Do not click the action again or issue another Registry
POST.

The controller closed the window automatically. Deactivate and Status restored API
`ca-gateway-api-dev--canaryclosed-20260828075643` and, after the final diagnostic
snapshot, worker `ca-gateway-worker-dev-vnet--inert-20260828080507`. The temporary
verifier revision was explicitly deactivated; the runtime revision is the sole
active worker revision. Final SQL evidence proves outbox zero and awaiting-admin
zero; final queues remain v3 `0/0/0`, v2 `0/0/3`, historical `0/0/2`.

## Historical closed Arm rehearsal (not the current resume path)

This section records an earlier initial-admission rehearsal only. The current
post-registration operation must not run `Arm`; use the narrow completion rearm in
the upgrade runbook.

Using `live-state-20260826-arm-preflight.json`, controller `Arm -WhatIf` passed every
database, queue, reviewed-DLQ-artifact, reconciled-FIC, RBAC, VNet, SQL, exact
ten-role, provider, image-digest, and deployed-configuration gate without mutation.
Actual `Arm` then deployed and verified the worker first and the API with admission
still false. `OpenAdmission` was not called, the signed-in browser submitted no
form, and no registration, Gateway key, Agent ID, or Agent 365 resource was created.
Controller `Deactivate` completed successfully.

The read-only checkpoint at `2026-08-26T03:54:28.0619100Z` proves:

- API `ca-gateway-api-dev--canaryclosed-20260826125053`, admission false and no
  expiry;
- worker `ca-gateway-worker-dev-vnet--inert-20260826125053`, all execution,
  Registry, and relay gates false;
- v2 queue active zero, scheduled zero, and retained DLQ two;
- the reviewed API and worker image digests are unchanged; and
- the historical worker remains unchanged.

At that checkpoint the signed-in browser reported catalog `12/7/5` and offered
`simple-echo-agent Blueprint`. This is point-in-time evidence, not the current
catalog count. Direct Azure CLI delegated token
acquisition for the API failed `consent_required` and made no state change. Do not
grant Azure CLI delegated consent as a workaround.

## First bounded canary failure: incompatible blueprint

Evidence captured at `2026-08-25T02:09:37.7829674Z`:

| Field | Value |
|---|---|
| Gateway registration | `637b600d-2c82-491d-b667-3c75108c1b2f` |
| Operation | `3c651663-505f-4bb5-bf2c-f240c080037c` |
| Selected typed blueprint | `pat-blueprint` |
| Terminal state | `RequiresManualIntervention` |
| Failed stage | `ResolveBlueprint` at 0% |
| Error | `AGENT365_PLATFORM_ACCEPTANCE_UNCONFIGURED` |
| Workflow-v2 queue afterward | active 0, scheduled 0, DLQ 1 |

The selected blueprint's `managerApplications` collection was empty while the
Direct Registry preview provider required the reviewed Agent 365 first-party
manager application. Worker evidence contains exactly one Graph GET of the selected
typed blueprint. It contains no POST, PATCH, PUT, or DELETE before failure.
Therefore this canary created no blueprint principal, FIC, child Agent Identity,
app-role assignment, Registry record, or Agent 365 mapping.

The Gateway registration and operation are real Gateway records but are not a
provisioned Agent 365 agent. Their one-time credential was not copied into this
checkpoint and must not be recovered or reused. The identified v2 DLQ message and
registration are manual-intervention evidence:

- no retry or replay;
- no receive, settle, purge, delete, or dead-letter forwarding;
- no destructive compensation;
- no claim that the Microsoft resources exist.

The tracked redacted evidence record is
`evidence/canary-failure-20260825.json`.

## Second bounded canary failure: delayed FIC visibility

| Field | Value |
|---|---|
| Gateway registration | `ae197b30-0fe8-4d31-8300-dbac7cad3ec2` |
| Operation | `424808e5-db7d-4935-bc5d-9dc99b1fc12e` |
| Selected typed blueprint | `simple-echo-agent Blueprint` (`76d144d9-7b6c-4448-b43f-76c1ae12cde5`) |
| Terminal state | `RequiresManualIntervention` |
| Failed stage | `ConfigureGatewayFederation` at 28% |
| Error | `PROVISIONING_AMBIGUOUS_RESULT` |
| Workflow-v2 queue afterward | active 0, scheduled 0, DLQ 2 |

`ResolveBlueprint` and `EnsureBlueprintPrincipal` completed. The worker observed an
empty FIC list, sent exactly one FIC POST, received HTTP 201, and then immediately
observed a stale empty list. It failed closed and made no later Microsoft mutation.
A later read-only Graph reconciliation found exactly one deterministic FIC:

- ID `fea6b67c-008a-49aa-9672-6b98500d3d97`;
- expected deterministic name;
- expected development tenant issuer;
- v2 worker managed-identity principal as subject;
- sole audience `api://AzureADTokenExchange`.

This FIC is a valid reusable Gateway-to-blueprint federation resource. Preserve and
reuse it; every authorized registration must discover it with GET and issue no FIC POST. No
child Agent ID, Agent 365 app-role assignment, Registry record, or telemetry mapping
exists for this operation. Its one-time Gateway key is not retained in evidence and
must not be reused. The evidence record is
`evidence/canary-federation-failure-20260825.json`.

## Third bounded canary failure: Registry outcome unknown

After action-time confirmation, registration
`b23cb073-912e-4efa-8a01-88a46b2af5fb`, operation
`8ece1c62-df73-4185-8f73-7b27db080414`, and external ID
`agent-f3e843a9784f4700a6cb860c80286d67` were created for the compatible
`simple-echo-agent Blueprint`. Agent 365 observability was on; Azure Monitor and
Purview were off.

The worker GET-reused the existing FIC with zero FIC POST, created and read back
child Agent ID `8e4859bd-477c-4133-adb1-9030ec13bf5c`, and assigned and read back
`Agent365.Observability.OtelWrite`. Its one POST to the documented
`/beta/copilot/agentRegistrations` route returned HTTP 500 without a durable Registry
ID. The operation is `RequiresManualIntervention` at `RegisterAgent` (71%) with
`PROVISIONING_AMBIGUOUS_RESULT`; the Registry-create outcome is unknown.

The controller detected v2 DLQ changing to three and recovered API
`ca-gateway-api-dev--failclosed-20260826162921` closed and worker
`ca-gateway-worker-dev-vnet--inert-20260826162921` inert. Evidence is
`evidence/canary-registry-failure-20260826.json`. Preserve the registration, message,
FIC, child, and role assignment. Do not retry or issue another Registry POST. Current
official Learn documentation supports application authentication, the create/known-
ID GET endpoints, and their ReadWrite/Read permissions. The API remains beta,
Global-only, and unsupported for production; it has no list or `sourceAgentId`
reconciliation route. Learn defines `sourceAgentId` as the source-system ID, so the
Gateway external ID remains correct. After MFA and explicit Admin Center Refresh,
exact searches for `canary-simple-echo-20260826072647` and child
`8e4859bd-477c-4133-adb1-9030ec13bf5c` each returned 0 of 341 agents. This portal
evidence shows no visible record but does not eliminate an unknown backend effect.
Official `Microsoft.Agents.A365.DevTools.Cli` 1.1.214 at commit `90c4448` uses a
client-generated ID and known-ID GET. That investigation later informed the
workflow-v3 delegated, planned-ID contract. Its AgentX-specific source/manager/CLI-ID
values were not copied verbatim, and the historical app-only Gateway contract was
retired.

## Earlier bounded admission window: no submission

The corrected controller opened an API-enforced window with absolute expiry
`2026-08-25T06:22:06.7226437Z`; revision readiness completed and the operator window
deadline was `2026-08-25T06:19:35.7579604Z`. No registration was submitted in the
signed-in Admin UI. The controller closed admission normally and a subsequent
`Deactivate` completed successfully. Post-window read-only evidence showed:

- API revision `ca-gateway-api-dev--canaryclosed-20260825152151`, admission false,
  and no expiry setting;
- worker revision `ca-gateway-worker-dev-vnet--inert-20260825152151`, all execution/
  Registry/relay gates off and desired scale `0..1`;
- workflow-v2 and historical queues both Active at active 0, scheduled 0, DLQ 2;
- the authenticated Admin UI list still contained four results: two older drafts and
  the two retained manual-intervention canaries.

This window is controller evidence, not a provisioning canary or Microsoft mutation
record. At that checkpoint the last direct SQL artifact predated the window, so new
SQL/outbox evidence was required. The 2026-08-26 recovery and live-state evidence
above fulfilled that checkpoint; the controller still requires a newer
just-in-time live-state/outbox proof immediately before `Arm`.

## Historical fail-closed checkpoint before continuous mode

This state was superseded by the healthy continuous-development revisions in
Current disposition. It is retained only to explain the earlier recovery evidence.

- Workflow-v3 API registration and delegated-action admission are closed.
- Workflow-v3 worker processing/provisioning execution and outbox relay are inert on
  sole active latest/ready digest-pinned runtime revision
  `ca-gateway-worker-dev-vnet--inert-194331`; it has no command/argument
  override or `DATABASE_MIGRATOR_*` setting.
- `gateway-provisioning-v3` is Active with zero active, zero scheduled, and eight DLQ
  messages.
- `gateway-provisioning-v2` is Active with zero active, zero scheduled, and exactly
  three retained DLQ messages.
- the historical queue remains zero active/scheduled with its two older DLQ messages
  untouched;
- SQL finalization remains unapplied.

There is no implied activation or retry. A healthy Container App revision alone
does not prove gates, queue ownership, or database state; the paired final SQL and
queue evidence above provides the current recovery checkpoint.

## Deployed contract and newer local hardening

The compatibility guard is deployed:

- the typed Graph catalog selects `managerApplications`;
- every row exposes `isAgent365Compatible` plus a safe issue message that never
  exposes configured manager IDs;
- compatibility requires all configured manager IDs to be present; extra blueprint
  managers are allowed, while empty API configuration marks every row incompatible;
- the Admin UI disables incompatible choices and reports the compatible count;
- registration POST rechecks compatibility before persistence or one-time key
  issuance and returns HTTP 422
  `AGENT_IDENTITY_BLUEPRINT_INCOMPATIBLE` on mismatch;
- the worker retains its final compatibility recheck;
- API Bicep supplies the same indexed `Agent365__ManagerApplicationIds__N`
  configuration as the worker.

The historical workflow-v2 API/worker contract and its application-authenticated
Registry boundary remain only as retained evidence. The deployed workflow-v3 path
supersedes it:

- the worker performs only the first five Microsoft stages, pauses at 71%, and
  never calls the Registry;
- a user-only API endpoint accepts the signed-in Gateway Administrator's delegated
  token and obtains the two Registry scopes through OBO;
- the API persists intent, emits at most one Registry POST, and persists the safe
  returned/fallback ID immediately on HTTP 201; immediate exact GET is not required
  because the preview collection is not reliable for just-created records;
- the API persists a creator-bound planned Registry ID before its one POST; the
  CLI-compatible payload includes that `id` and the reviewed preview-provider
  `managedByAppId`, while `sourceAgentId` remains the Gateway external ID and
  `createdBy` is the administrator `oid`;
- HTTP 201 persists the safe returned ID immediately, using the planned ID only
  when a successful response omits one; accepted create completes Register at 85%
  and atomically queues only final
  worker verification; and
- final worker verification never calls Registry and requires durable delegated
  Registry evidence plus reverified blueprint/FIC/child/OtelWrite/token state.

An unknown POST outcome permits exact planned-ID GET only; the POST is never
repeated. Transient reads remain creator-bound and GET-only, while mismatch or
nonrecoverable ambiguity is manual. Safe retry after an accepted Registry stage
clones the six-step prefix and resumes only final verification. The provisioning-
state planned-ID/app-only helpers remain historical compatibility; the API attempt
planned ID is current.

The controller separates a 30--300 second operator window (default 120), started
only after revision readiness/preflight, from a 60--300 second rollout allowance
(default 300). It writes the API expiry before rollout, caps total exposure at 600
seconds, and closes API admission first in `finally`. PowerShell JSON handling
preserves the RFC 3339 UTC string instead of locale-converting it. The registration
revision is also bound to exactly one generated external ID, with retry unset; the
separate completion revision is bound to exactly one resulting operation ID.

The corrected working-tree controller now has three distinct database inputs:

1. immutable two-pass live-prepare provenance whose exact script names and current
   SHA-256 hashes are validated, without rejecting it merely for age;
2. fresh phase-`verify`, repeat-one live state with zero scripts, workflow v2 ready,
   legacy index one, and publishable outbox zero; and
3. a fresh, distinct recovery baseline with workflow v2 absent and legacy index one.

It rejects any live-finalize input. The explicit empty-outbox timestamp must equal
the live-state `VerifiedAtUtc` exactly and still pass the shorter outbox freshness
window. This prevents an unrelated operator timestamp from being paired with stale
SQL evidence and prevents rerunning live prepare solely to satisfy freshness.

The exact current release counts live in `../implementation-status.md` and must be
refreshed only after all test projects run. This is local evidence only.

The successful pre-canary controller invocation used the then-current DLQ2 baseline:

```powershell
$canary.ReviewedCanaryFailureEvidencePaths = @(
    (Resolve-Path 'docs/operations/evidence/canary-failure-20260825.json')
    (Resolve-Path 'docs/operations/evidence/canary-federation-failure-20260825.json')
)
$canary.ExpectedWorkflowV2DeadLetterCount = 2
```

That invocation is historical v2 evidence. Do not reuse its DLQ2 inputs or merely
change the value to three for workflow v3. The reviewed v3 controller must treat the
retained v2 DLQ3 as an isolated, immutable baseline while validating the distinct v3
queue; evidence validation never authorizes message access or disposition.

## Safe v3 data-plane proof helper

For a future authorized Active registration, use
`tools/invoke-gateway-data-plane-canary.ps1` for the bounded ingress proof. Copy only
the one-time Gateway key from the Admin UI to the Windows clipboard, then start the
helper from PowerShell 7 with public identifiers only:

```powershell
pwsh ./tools/invoke-gateway-data-plane-canary.ps1 `
  -ApiBaseUrl 'https://{gateway-api-host}/' `
  -ExternalAgentId '{fresh-v3-external-agent-id}' `
  -TenantUserObjectId '{real-tenant-user-object-id}'
```

Do not use `Start-Transcript`, tracing, output redirection, or a key argument. The
helper reads and validates the key, clears the clipboard immediately, retains it only
in process memory, and waits for Enter. Press Enter only after the operation reports
`Active`. It must report exactly HTTP 403 for a registration-mismatch activity, HTTP
202 for the matched activity, and HTTP 202 for the matched interaction; it prints
only statuses and safe correlation IDs, never bodies or the key. Any other status is
failed/inconclusive evidence: close all gates and do not improvise a retry. The full
procedure and downstream-landing boundary are in
[`agent365-observability-setup.md`](agent365-observability-setup.md#bounded-data-plane-proof).

## Next safe actions

### Local-only Purview protection-profile checkpoint (2026-08-29)

The working tree now contains an unreleased Admin UI/API/worker implementation for
selecting or creating a Gateway-managed Purview protection profile when creating a
new blueprint. It preserves workflow v3 and performs the policy assignment inside
`ResolveBlueprint` before child creation. The additive SQL script is
`infrastructure/sql/20260829_purview_policy_profiles.sql`; the worker image adds
PowerShell 7.5 and ExchangeOnlineManagement 3.10.1. No Azure revision, SQL schema,
tenant policy, identity role, certificate, queue, or live registration was changed
for this checkpoint. Do not treat local tests or Bicep compilation as deployment
evidence.

The latest local increment also treats the persisted provider IDs and authorized
blueprint-application set as the only policy authority, rejects extra scope,
exclusions, bypass, conditions/actions, or unexpected modes, requires proven
temporary PKCS#12 cleanup, and revalidates the exact collection/DLP/rule contract in
the final workflow stage before `Active`. This hardened runtime has no deployed
worker revision or live tenant canary. The earlier live `AuditLogged`/`Blocked`
evidence below applies to the deployed Graph data-plane adapter, not this unreleased
provisioning automation.

Before a reviewed development rollout, verify the automation application has
`Exchange.ManageAsApp` and only the required Purview compliance RBAC, verify its
certificate secret is versionless and readable by the worker identity, deploy with
`purviewPolicyProvisioningEnabled=false`, apply the additive migration, and complete
read-only preflight. A live enablement and one bounded new-blueprint canary require a
separate authorization entry here.

1. Keep continuous registration, delegated completion, and relay confined to the
   development deployment. Preserve v3 `0/0/10`, retained v2 `0/0/3`, historical
   `0/0/2`, and every retained Microsoft artifact.
2. Promote the same source through a staging review that restores exact-bound
   admission, validates multi-replica/failover behavior, and captures fresh SQL
   outbox/job evidence.
3. Keep Purview policy locations blueprint-scoped. Prompt Shields is now deployed
   and proven independently from Purview. The next prompt-protection gate is staging
   multi-replica, dependency-outage, expiry/mismatch, and failover validation.
   Response-before-release enforcement remains separate because `downloadText` is
   currently offline.
4. The recreated Purview PAYG association is sufficient for the live prompt canary:
   the allowed evaluation returned `AuditLogged`. Preserve the established Purview
   policy and do not infer response-side inline enforcement from that result.
5. Apply SQL finalization and perform any production rollout only as separate,
   reviewed workstreams.
6. Prove `bootstrap/bootstrap.ps1` in a disposable clean development subscription,
   not this evidence-bearing resource group. Capture its safe state, template
   ownership/source-fingerprint outputs, accepted-source snapshot provenance, image
   digests, exact Key Vault scopes, temporary SQL-rule cleanup, empty-schema
   initialization, final preflight, one real registration/data-plane canary, and
   Purview propagation/verdict before marking clean-subscription recovery
   live-proven.

## Historical boundary

The historical workflow-v1 operation
`3c156bdc-4aa3-4802-81f8-5595e037d0e5`, its worker, and the two old DLQ messages
are not workflow-v2 inputs. They remain outside this rollout and must not be replayed
or reinterpreted. The 2026-08-24 SQL-connectivity incident is retained at
[`incidents/2026-08-24-provisioning-worker-sql-connectivity.md`](incidents/2026-08-24-provisioning-worker-sql-connectivity.md)
as historical evidence; its old workflow shape is not current design.

## Authorization and secrets

Continuous development admission is intentionally enabled, but this checkpoint does
not authorize replay of a historical operation, a second POST, attachment/deletion
of retained resources, DLQ access or disposition, production action, destructive
cleanup, unrelated mutation, or SQL finalization.

`.secrets` is authorized private runtime input only. Existing tooling may consume
required values through its non-echoing path. Never print, log, document, copy,
alter, or commit it. Never record clear Gateway keys, access tokens, managed-
identity assertions, authorization headers, or raw dependency bodies.
