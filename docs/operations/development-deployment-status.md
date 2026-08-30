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

The baseline Phase 6 candidate for this chronology was frozen on branch
`codex/phase6-candidate` at source commit
`1cdd5eb2deaefa3ba6989308566806f0920c2305`. The exact-account boundary now
acquires Microsoft Graph access through `az account get-access-token` with the
reviewed subscription, verifies returned subscription/tenant/type/lifetime
metadata, and sends only bounded Graph v1.0 requests through an in-process,
no-redirect client. Supported post-authentication code rejects native `az ad` and
`az rest`; the workflow-v3 helper also verifies that its loaded Common module is
the accepted-source file or a byte-identical source-bound copy.

That baseline local candidate gate was a zero-warning/zero-error Release build and
**1,304/1,304** direct Release tests: unit 479, Admin UI 155, local Setup 75,
observability/runtime 149, integration 92, end-to-end 106, architecture 115, and
security 133. Pester discovered **369** tests: **368** passed, none failed, and one
Windows-only launcher test was skipped on macOS. The canonical source gate parsed
**19** PowerShell files and **2** JSON contracts and compiled all **25** Bicep
templates plus **5** parameter files; `dotnet format --verify-no-changes` and
`git diff --check` are clean. Focused terminal-deployment recovery passes **70/70**
and existing-deployment image-pull compatibility passes **23/23**. The bounded
interactive-user canary lifecycle/state gate passes **27/27**, and its exact
Microsoft identity/evidence subset passes **22/22**. Independent settled-diff
correctness/security reviews found no blocking issue. These are local-source
results, not live deployment proof.

The retained `a365gw7-dev` generation is frozen in resource group
`rg-a365-custom-gw-phase6f`, ownership
`9593d817-e3ea-4643-ae49-e15dbfaaede6`, and ACR
`acra365gw7devv47vkw`, exclusively in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Accepted Plan
`sha256:0b1abe3e43efb282bd38070106aa8f8dae53dc2234e8f2b45b7d440e08c115aa`
bound configuration
`sha256:233278aa4965c14ffa7b5615df06edee7d0a9a65716c1877cf8ed29166fc6f79`
and source
`sha256:be92f53543729e6a467500db73dc4165c0f22e62762c05b758ad5edf992958ab`;
What-If reported exactly six Creates and zero Deletes. Apply reached **6/19** and
produced exactly three succeeded immutable `QuickRun`s: API `de1`
`sha256:c6c5ad170b1de22460f2407d75aea1bd66f9c7502c009ac6b163b1cb92345752`,
worker `de2`
`sha256:9db329085a8c3be1bc85d684be9cf183742ce41a45e6d9970bf1ab07f858550a`,
and Admin UI `de3`
`sha256:197ecf9594670c819c39a6b1b8f60914aeda713e405ed69819af0bf225aee34e`.
Gateway API application object/client/service-principal IDs are respectively
`2d33d7eb-8a70-4ace-a79f-567cbbb3f6b2`,
`722bb149-4e34-4d61-bd05-6778af55f7ca`, and
`26e140fc-ae19-4fb1-889c-857128d01b28`.

Inert deployment `a365gw-a365gw7-bootstrap-inert-dev` reached terminal `Failed`
at `2026-08-29T19:32:39.849702+00:00`. All dependency nested modules succeeded;
`deploy-worker-app` failed at the private-ACR first-pull boundary. The API app is
absent. Partial worker `ca-gateway-worker-dev-v3` is failed with no revision and
system-assigned principal `57fbc79c-fcc9-44a3-9395-c82efd1a3d7f`. The circular
ordering was exact: the system identity needed an `AcrPull` role that could be
assigned only after the app existed, while the app's first revision needed to pull
the image before becoming provisioned. No provider body was emitted or persisted;
safe diagnostics are
`.bootstrap/diagnostics/a365gw7-dev-20260829-193316.json`.

No runtime activation, database initialization, Agent 365 blueprint, workflow
identity, Admin UI, registration, canary, Gateway-key, Registry, or Purview action
completed. Preserve all `a365gw7` state, snapshots, shared foundation, Entra app,
three images, terminal deployment, and partial worker identity. It must not Resume
with changed source. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated, and its
queues/messages were not accessed.

Commit `16138105ecf9a05deed2c275b39e4f850a10f924` creates and grants one exact
source/owner-bound pull UAMI before workloads, enables ACR managed-identity ARM-
audience authentication, and makes API/worker registry pull use that identity
while retaining system identities for runtime authority. It also permits only an
exact terminal `Failed`/`Canceled` same-name Incremental recovery after durable
checkpointing and exact source/owner/parameter/partial-app validation. Nonterminal,
unknown, or drifted state fails closed. Existing-deployment compatibility requires
an exact explicitly authorized historical contract or an already-migrated exact
dedicated-identity contract; it performs no migration, role deletion, or cleanup.
The next live action is fresh isolated project `a365gw8` in absent resource group
`rg-a365-custom-gw-phase6g`, only in the target subscription above. `a365gw7` is
frozen evidence, not a Resume candidate.

Fresh `a365gw8-dev` then used resource group
`rg-a365-custom-gw-phase6g`, ownership
`e7aa5755-7e7f-448c-a7ef-92dadc054235`, and ACR
`acra365gw8devphvcbm`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Initial Plan
`sha256:8668df4700ca605e941adf7c455f4cf8e0fa568178d116542e0c450d3491417e`
bound configuration
`sha256:17b21308b8e58d78f2c8dab53775af91843157c128bf4ee8082fbec92947c37f`
and source
`sha256:eddc62123a1ee6d8d68540d0f5b560485c30d02a1a3f6c9a55e6bb0705b91c86`;
authenticated What-If reported exactly eight Creates and zero Deletes.

Apply completed Prerequisites and Azure authentication, then was deliberately
interrupted before provider/resource mutation. Status preserved **2/19**, 10%,
and Azure provider registration as the next step. Resume recomputed the identical
Plan, completed provider registration, and submitted the foundation. Subscription
deployment `a365gw-a365gw8-bootstrap-foundation-dev` succeeded at
`2026-08-29T20:47:03.973590+00:00`. It created pull identity
`id-gateway-runtime-pull-dev`, principal
`28533d8c-e205-424e-b4f1-6457a47f1731`, and deterministic exact ACR-scoped role
assignment `97063172-3842-5639-a570-9f50dfd5586e`.

Bootstrap stopped at **3/19** during exact foundation validation. Azure CLI 2.89.1
typed `az acr show` returned null for
`azureADAuthenticationAsArmPolicy`, although exact generic ARM readback at API
`2023-11-01-preview` returned `enabled`; identity, role, owner, and source fields
also matched. Recovery Plan
`sha256:0a2ef13a962f3499cdc379c2eec7d84c511bee5bf7ac8511a470240a2d2a3f5b`
reported exactly eight Deploy actions and zero Deletes. Its Resume failed closed on
the same projection without replaying the already-succeeded deployment. Safe
diagnostics are `.bootstrap/diagnostics/a365gw8-dev-20260829-204735.json`.

No API Entra identity, ACR build, Container App, SQL initialization, Agent 365
blueprint, workflow identity, Admin UI, registration, canary, Gateway-key,
Registry, Service Bus queue/message, or Purview action followed. Preserve all
`a365gw8` state, snapshot, foundation, ACR, pull identity, and role evidence; it
must not Resume with edited source. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated, and its
queues/messages were not accessed.

Commit `78ef1c0fc5b81005a9ec56c4adde044ed6aeb900` changes all three ACR ARM-audience
checks to exact resource-ID, target-subscription reads pinned to the same
`2023-11-01-preview` ARM API as Bicep. Absent properties, disabled policy, API
failure, wrong ID, or owner/source drift still fail closed. The full current local
gate and independent review are recorded above.

The latest retained live generation is `a365gw9-dev` in resource group
`rg-a365-custom-gw-phase6h`, ownership
`fc045585-0296-4e3c-a27f-00c3aa017f59`, and ACR
`acra365gw9devisqxpa`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Initial Plan
`sha256:1bc13d8f4b4c8b412308ae91de6b5440506aa9f68f7f1f8cdc799c7edbb09df9`
bound configuration
`sha256:7dd28b4a5c9c9589cb2c179630e4179fa183a7b242749ab69f54ab70a27c9c87`
and source
`sha256:ff0fe552aa52f478cb8cfc08a126f1e4f76a13f4bc9e222ae9c1c3545a067b4f`;
authenticated What-If reported exactly eight Creates and zero Deletes. Apply
completed Prerequisites, exact Azure authentication, provider registration,
foundation, Gateway API identity, and all three immutable image builds. Pull
identity principal `7aabeaf0-c67c-4d82-8cda-28733920b934` has exact ACR-scoped
`AcrPull` assignment `3e3bf721-f4b6-5140-8d54-8af36b559a4f`. The exact succeeded
`QuickRun`/digest pairs are API `de1`
`sha256:a204d6a54b95fab7cc5b9edc03772aecec77a301e63a756a1a35daaf57de1bba`,
worker `de2`
`sha256:d9a6822a9262156e1501166133071468d550bf6e18494534c4bd023664f858e6`,
and Admin UI `de3`
`sha256:168987bba384b9e053cd948c9fbced45b3ee7eb07fb340c1c4717c2af9fb9ded`.
Gateway API application object/client/service-principal IDs are
`e4240e2f-e0d0-40aa-80d7-d6ba85b43388`,
`107b5119-fa96-44af-9b39-3aae9fc65c0e`, and
`b9fe7e69-4305-40c8-b16e-2bd06caed702`.

Bootstrap stopped safely at **6/19**, 31%, before inert ARM deployment because a
local guard still conflated the project-scoped delegated-scope URI with the bare
v2 API token audience. Safe diagnostics are
`.bootstrap/diagnostics/a365gw9-dev-20260829-211549.json`. No Container App,
database initialization, Agent 365 blueprint, workflow identity, Admin UI,
registration, canary, Gateway-key, Registry, Service Bus queue/message, or Purview
action followed. Recovery Plan
`sha256:655ecacf57bf726a9bb999436c816fab38d6cf807f9d7d622231ed283878a2ca`
was accepted before the correction and is also frozen. Preserve all state,
accepted snapshots, foundation, API identity, and images; do not Resume either
Plan with edited source. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated, and its
queues/messages were not accessed.

Commit `1cdd5eb2deaefa3ba6989308566806f0920c2305` independently binds the custom
delegated-scope URI and bare-client-ID v2 audience and adds the reviewed bounded
interactive-user canary/recovery lifecycle. The next live action is fresh isolated
project `a365gw10` in absent resource group `rg-a365-custom-gw-phase6i`, only in
the target subscription. `a365gw8` and `a365gw9` are frozen evidence, not Resume
candidates.

Fresh `a365gw10-dev` then used resource group
`rg-a365-custom-gw-phase6i`, ownership
`c388ba75-6a77-45b7-a2d2-e3c4bce8e99d`, and ACR
`acra365gw10devg6eltw`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Accepted Plan
`sha256:f83b11d238e722ca3396a390a9fa0802f3f55ba7e29dba1f4413536dfb734c0c`
bound configuration
`sha256:c1847f79831db3c1ea1dec85e6c3f1a3b9e0b05f9a2632a81895f65a76ee6f01`
and source
`sha256:a2f22eda691af86fc61cac1bd1e3309382520ed6a9b246736dbdc5df9b6a4c6b`;
authenticated What-If reported exactly eight Creates and zero Deletes. Apply
completed Prerequisites and exact Azure authentication, then was deliberately
interrupted at the start of provider registration. Persisted status was `Paused`
at **2/19**, 10%, with no resource mutation. Resume recomputed the identical Plan,
revalidated both completed checkpoints, and continued only in the target
subscription.

Resume completed provider registration, foundation, Gateway API identity, and all
three immutable images. Pull identity principal
`ee85af3d-8fc0-4d94-9666-430519dcbd20` has exact deterministic ACR-scoped
`AcrPull` assignment `e0f5a084-0f56-5b8b-8cd6-9aa93d50e856`. API, worker, and
Admin UI `QuickRun`s `de1`, `de2`, and `de3` produced digests
`sha256:6a44f3fbe718d4f050c487cc13ad9ca9bab645c2c6b16bd12a2b9bbd68909861`,
`sha256:247d7257736cfb2ca8dcc0a30403f01e707146b02361fd216305b4fcebdd6171`,
and
`sha256:e5c5bf8328ea682ccb1650d67e82cbc88e41857b77fe22f3a79e7448cbff7113`.
Gateway API application object/client/service-principal IDs are
`9798e855-f286-4315-b798-1cead0df0c0d`,
`26c59e63-a339-419b-bbb5-0e5701ba869f`, and
`ac862a1a-6109-4503-a8b3-0d97af9d2c74`. Its scope base URI is
`api://a365-gateway-a365gw10-dev`; the v2 token audience is the bare API client ID.

Inert deployment `a365gw-a365gw10-bootstrap-inert-dev` and every observed nested
deployment reached `Succeeded` under correlation
`b283f5b9-f9b4-4b93-ac78-05371854a3df`. Bootstrap then stopped during immediate
strict post-deployment validation and preserved **6/19**, 31%. Safe diagnostics
are `.bootstrap/diagnostics/a365gw10-dev-20260829-233308.json`. A read-only recovery
Plan
`sha256:8aafa9d8ea77535dcfdbff7b0df00f65ece3d1a9d2a3cbc8065219c14f35ca6e`
reported exactly eight `Deploy`, twenty-five `Ignore`, and zero `Delete` changes.
The current categorical validator rejected `Ignore`, marked that Plan not
apply-ready, and cleared the earlier acceptance before any further mutation.

The twenty-five ignored IDs are the existing inert graph omitted from the
subscription-level foundation template. They cannot be accepted by prefix, count,
or tag alone: the correction must require exact set equality against a GET-only,
Succeeded/Incremental, source/owner/parameter/resource-bound recovery graph,
including the single private-endpoint-generated NIC and SQL `master` parent
bindings. The succeeded deployment also exposed a strict recovery-surface defect:
ARM records the reviewed default `allowLegacySystemAssignedImagePull=false`, while
the local expected parameter dictionary omitted that name. Preserve `a365gw10` and
never reconstruct its acceptance or Resume it with edited source. No database
initialization, seed blueprint, workflow identity, Admin UI identity/credential,
runtime activation, registration, Gateway key, Registry, canary, or later Purview
action followed. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated, and its
queues/messages were not accessed.

Commit `bb001483bae0577d7c29a9638c1c7275dae44525` now implements the independently
approved bounded recovery contract. Plan contract v3 binds the complete boundary;
only exact-case `Ignore` predictions can enter recovery, and only after exact
persisted source/configuration/owner/prefix checks. GET-only validation requires the
Succeeded Incremental deployment, all 76 readable parameters, the exact sorted
25-resource graph and per-type inventories, deterministic ownership tags, alert and
dependency relationships, the generated NIC reverse binding, and the SQL `master`
binding. All malformed, mixed-case, duplicate, cross-type, expanded,
Prompt-Shields-enabled, or provider-drifted shapes fail closed. The shared Azure
command boundary pins every recovery read to target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`; no recovery-only path can invoke ARM
deployment mutation.

A sanitized GET-only smoke against frozen `a365gw10` proved the exact graph and
boundary fingerprint
`sha256:48adf18a485c1fa2a4ca186324a14be78242f63b72bb68ee3e93319f7f5e65d9`
without reconstructing acceptance or invoking Resume. Focused tests pass 178/178.
The canonical gate passed 430 Pester tests with one expected macOS skip, parsed 19
PowerShell and 2 JSON files, and compiled 25 Bicep templates plus 5 parameter files.
Direct Release tests pass 1,304/1,304; the Release build has zero warnings/errors,
format verification passes, and `git diff --check` is clean.

Fresh generation `a365gw11-dev` used absent resource group
`rg-a365-custom-gw-phase6j`, ownership
`593edace-3230-4c77-b648-e8d6a163d965`, and ACR
`acra365gw11devlumzmj`, only in target subscription `internal-security-lab-02`
(`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`). Its accepted Plan
`sha256:82fc6bf0368ed1fd52b7d118d21848dce834c51f261363e187a3b2b90f101e86`
bound configuration
`sha256:a8ac824b365aa0243900b53df1cb3d453d1feaa5ab3e89bba4f17f52534dfc4d`
and source
`sha256:4428dc6da2b894b0e986938b35dc1f2786e1a4f805bf92b4c0c2306fda9d226a`;
authenticated What-If reported exactly eight `Create` predictions and zero other
changes, all in that target subscription. The run window was
`2026-08-30T00:26:07Z` through `2026-08-30T00:51:22Z` (09:26–09:51 KST).

Apply completed durable steps 1–6: Prerequisites, exact Azure authentication,
provider registration, foundation, Gateway API identity, and immutable images.
API, worker, and Admin UI ACR `QuickRun`s `de1`, `de2`, and `de3` all reached
`Succeeded` and were digest-checkpointed as respectively
`sha256:429177cfb745fe3cae122fae5e51d676699709faf0f6340097566aa10e67c274`,
`sha256:1f989a3f6945ef4470a39aa967262154feedb8e8b91422b2b8977849d3bc0dba`,
and
`sha256:f5a1c9786f05c041f59e5b1e8fbfcf411d024457bb78b440303c67736da03ead`.
Foundation deployment `a365gw-a365gw11-bootstrap-foundation-dev`, inert deployment
`a365gw-a365gw11-bootstrap-inert-dev`, and every observed nested deployment reached
`Succeeded`.

Bootstrap nevertheless failed closed during step 7's immediate strict readback.
For the fourteen Container App environment values produced from Bicep
`string(bool)`, ARM returned `True` or `False`, while the validator required
lowercase `true` or `false`; the first mismatch was
`Provisioning__ExecutionEnabled` (`False` deployed versus `false` expected). All
earlier provider-shape predicates passed. State therefore records steps 1–6
completed, step 7 `Failed`, and no step 8 or later state. No database
initialization, seed blueprint, workflow identity, Admin UI identity/credential,
runtime activation, registration, canary, Gateway key, Registry, Purview, or later
phase followed.

Independent GET-only provider-shape and recovery audits corroborated the bounded
diagnosis without deployment mutation. A second no-queue exact environment check
with the corrected validator passed both complete API/worker environment sets and
all **14/14** Boolean values. This read-only evidence does not authorize Resume:
correcting the validator changes the accepted source fingerprint. Preserve the
`a365gw11` state, accepted snapshot, deployed graph, identities, and images; never
reconstruct acceptance or Resume it under edited source.

Commit `a8d5a427f6728ff366a839f99aa9356aabd90254` centralizes the observed ARM
Boolean projection for inert recovery, immediate deployment validation, and final
Verify, while preserving ordinal name/value matching and the separate literal
lowercase `OutboxRelay__Enabled` contract. Both independent reviews approved the
settled correction. Focused tests pass **278/278**. The canonical source gate
discovered **433** Pester tests: **432** passed, none failed, and one Windows-only
launcher test was skipped on macOS; it parsed **19** PowerShell and **2** JSON files
and compiled all **25** Bicep templates plus **5** parameter files. Direct Release
tests remain **1,304/1,304**, the Release build has zero warnings/errors, and
format/diff checks pass.

That checkpoint reserved the next live generation as `a365gw12` in absent resource group
`rg-a365-custom-gw-phase6k`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated; none of
its queues or messages were accessed. No target Service Bus message was read,
received, peeked, replayed, or settled.

Fresh generation `a365gw12-dev` then used absent resource group
`rg-a365-custom-gw-phase6k`, ownership
`0262fab5-5488-49be-bcb5-8ab4ccff83ab`, and ACR
`acra365gw12devzrlb27`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Its accepted Plan
`sha256:1d38f7e591db817c9746d75c29f6ffa84ac484aa59249d595687a4efbe8cc2f8`
bound configuration
`sha256:ae68bb54439fa05f85d420b36f196086899f27ff78cae0d66fd0cf18d8b2a36d`
and source
`sha256:e7572f92d7bc1e0e2310936868beb39242e9061b0c095ebe37eb4938022f97dc`.
Authenticated What-If reported exactly eight `Create` predictions and zero other
changes, all in that target subscription. The accepted Apply window was
`2026-08-30T01:22:42Z` through `2026-08-30T01:40:45Z` (10:22–10:40 KST). An
external JSON-lines renderer failed while the one bootstrap process continued; no
second Apply or Resume was issued.

Apply completed steps 1–6. API, worker, and Admin UI ACR `QuickRun`s `de1`, `de2`,
and `de3` reached `Succeeded` with respective digests
`sha256:a49cfd13ddb53fdc412f7564b79f1135dd3a15362d2ab2bd9d1f4f695b70a78f`,
`sha256:c132903c613bf2fc7d731a10bb88644821f2606bc2c69a1598bec9df640c966d`,
and
`sha256:40b3ebc0f6ed216a40eb50af47ba978720e87b843d9791ca8c377220be395277`.
Foundation deployment `a365gw-a365gw12-bootstrap-foundation-dev`, inert deployment
`a365gw-a365gw12-bootstrap-inert-dev`, and every observed nested deployment reached
`Succeeded`.

Step 7 failed closed during strict readback because the accepted validator treated
`databaseAttestationDatabaseName` as a top-level ARM parameter. Bicep derives that
value internally and exposes only an output. Exact target-only GET proved the
deployment `Succeeded`, the top-level parameter absent, and the output present and
empty as required for inert mode. Under module StrictMode the optional-property
lookup returned null and its `.value` dereference raised a masked
`PropertyNotFoundException`. State contains exactly steps 1–6 `Completed`, step 7
`Failed`, and no step 8 or later record. No seed blueprint, workflow identity, SQL
initialization, Admin UI identity/credential, runtime activation, registration,
canary, Gateway key, Registry action, or later phase followed.

Independent read-only recovery reviews agreed that unchanged-source Resume would
GET-adopt the existing succeeded deployment and fail the same validator again;
edited source cannot reuse the accepted fingerprint. Preserve `a365gw12` state,
snapshot, graph, identities, and images and never Resume it. Commit
`15f5ee268f59fbc20de1b59734d5fd70d08e73b7` preserves parameter/output/evidence
validation for all five caller-supplied database-attestation values and validates
the derived database name across output/evidence only, with exact empty inert and
`GatewayDb` runtime expectations. Independent review approved the fix. The focused
Experience suite passes **73/73**. The canonical source gate discovered **449**
Pester tests: **448** passed, none failed, and one Windows-only launcher test was
skipped on macOS; it parsed **19** PowerShell files and **2** JSON contracts and
compiled **25** Bicep templates plus **5** parameter files. Direct Release tests
pass **1,304/1,304** (unit 479, Admin UI 155, Setup 75, observability/runtime 149,
integration 92, end-to-end 106, architecture 115, security 133); the Release build
has zero warnings/errors, and format/diff checks pass. The next live generation is
reserved as `a365gw13` in absent resource group `rg-a365-custom-gw-phase6l`, only
in the target subscription. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated, and no
Service Bus message data plane was accessed in either subscription.

Fresh generation `a365gw13-dev` then used absent resource group
`rg-a365-custom-gw-phase6l`, ownership
`123aedd4-c7c8-43ac-9be2-83e93c9b5dd1`, and ACR
`acra365gw13devgb7yh4`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Its accepted Plan
`sha256:196d1b7de0bc02e9a9d4ff93471dd0696364fe5cf1d9c9998a57baa142f401e6`
bound configuration
`sha256:064fe82443341bf8f76c1a89be56e832ee2b3bc41d0748268f50f11fd75dd474`
and source
`sha256:5f154f039dfbd7814f49aa6024ebadfcc9d40bcf3e9713f1fc02ef61bcf943b8`.
Authenticated What-If reported exactly eight `Create` predictions and zero other
changes, all in that target subscription. The accepted minimal profile was `dev`,
Registry preview enabled, exactly one reviewed manager application, Prompt Shields
disabled, and Purview disabled. The accepted Apply window was
`2026-08-30T02:00:29Z` through `2026-08-30T02:19:16Z` (11:00–11:19 KST).

Apply completed durable steps 1–6. API, worker, and Admin UI ACR `QuickRun`s
reached `Succeeded` with respective digests
`sha256:830347df6d1018735a04d851e862c00514433bfdbd303a6119585883b2e582b2`,
`sha256:b8a4d8ff401992310f10f766ac31200c439d6d86ab509108984ccba72e26f527`,
and
`sha256:851e692413a0896e13485d4133b8f695a0b3680671ad1f0cc752aa6dcd915592`.
Foundation deployment `a365gw-a365gw13-bootstrap-foundation-dev`, inert deployment
`a365gw-a365gw13-bootstrap-inert-dev`, every observed nested deployment, and both
Container Apps reached `Succeeded`.

Step 7 failed closed because PowerShell pipeline assignment collapsed the inert
empty `expectedManagerIds` array to null. Its sequence comparison was null-tolerant,
but the subsequent strict `.Count` environment loop raised
`PropertyNotFoundException`. Exact target-only GET proved ARM carried an empty
array parameter, Bicep emitted no manager-ID environment entries, both apps were
digest-pinned and secret-free, and the corrected database-name contract passed.
State records exactly steps 1–6 `Completed`, step 7 `Failed`, no promoted outputs,
and no step 8 or later record. No seed blueprint, workflow identity, SQL
initialization, Admin UI identity/credential, runtime activation, registration,
canary, Gateway key, Registry action, or later phase followed.
Message-count and SQL outbox evidence was not captured: SQL initialization never
started and no Service Bus message data plane was accessed. That absence is not a
zero-count claim.

Three independent read-only audits reproduced the exception and agreed that an
unchanged-source Resume would GET-adopt the succeeded deployment and fail the same
validator. A StrictMode GET-only run with only the outer array capture corrected
passed the complete live `a365gw13` validator. Preserve `a365gw13` state, accepted
snapshot, graph, identities, and images; never reconstruct acceptance or Resume it.
The bounded source audit found the same singleton collapse in the later Admin UI
delegated-scope revalidator and final Verify; its typed-array and join-only sites
remain safe.

Commit `c92757080b1465ca0e140919038ba0176a5e0eb1` applies outer array capture to
exactly those three direct-`.Count` assignments while retaining exact manager-ID
sequence and one-grant/resource/`AllPrincipals`/`access_as_user` requirements.
Independent review approved the correction and proved its AST regressions fail
against the pre-fix assignments. Focused Experience and Verification tests pass
**119/119**. The canonical source gate discovered **452** Pester tests: **451**
passed, none failed, and one Windows-only launcher test was skipped on macOS; it
parsed **19** PowerShell files and **2** JSON contracts and compiled all **25**
Bicep templates plus **5** parameter files. Direct Release tests pass
**1,304/1,304** with the established per-project totals, the Release build has zero
warnings/errors, and format/diff checks pass. The corrected deployment-affecting
source fingerprint is
`sha256:f0d03d165f7a4c71664eba46ad8c33ad562968e124ea293ccea07e7217eb2307`.
The next live generation is reserved as `a365gw14` in absent resource group
`rg-a365-custom-gw-phase6m`, only in target
subscription `6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated, and no
Service Bus message data plane was accessed in either subscription.

Fresh generation `a365gw14-dev` then used absent resource group
`rg-a365-custom-gw-phase6m`, ownership
`59b61c5f-7be5-44b2-a1a3-4d3819264cf2`, and ACR
`acra365gw14devwalxhk`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Its accepted Plan
`sha256:4c2c1caf0e22795a52164c814bcc38c98611f708b8065f8b7ffa0297e1eae39c`
bound configuration
`sha256:8979733f0231e5bfad1e706410b60d377008e4bce244357afa80dc0252914335`
and source
`sha256:f0d03d165f7a4c71664eba46ad8c33ad562968e124ea293ccea07e7217eb2307`.
Authenticated What-If reported exactly eight `Create` predictions and zero other
changes, all in that target subscription. The accepted minimal profile remained
`dev`, Registry preview enabled, exactly one reviewed manager application, Prompt
Shields disabled, and Purview disabled. The single Apply was accepted at
`2026-08-30T02:46:13Z` and stopped at `2026-08-30T03:07:42Z` (11:46–12:07 KST);
no duplicate Apply or Resume ran.

Steps 1–10 completed durably. Foundation deployment
`a365gw-a365gw14-bootstrap-foundation-dev`, inert deployment
`a365gw-a365gw14-bootstrap-inert-dev`, SQL private-endpoint deployment
`a365gw-a365gw14-bootstrap-sql-private-dev`, and all observed nested deployments
reached `Succeeded`. API, worker, and Admin UI images were checkpointed at
`sha256:777eadbeb87bec3518d3b84977b318d1b70bd3c7ec4990da5a310e82f9043db3`,
`sha256:bb1ea293692174900fc3d8144ee6bb9aaef0ad2a499b70b9ccfb69ac47802069`,
and
`sha256:fed1a0d17fde11e6a229e9e60fa33b68ffe2b4adef95fe62a8aa91ce1756028b`.
The source-bound, credential-free seed blueprint object/application ID is
`8e453b8d-8fe8-4a12-99a6-e083e753f597`; it retained exactly one reviewed manager
application. Workflow-v3 Entra configuration and the SQL private endpoint also
completed exact readback.

Step 11 failed within five seconds, before any step-11 database, firewall, or
SQL public-network mutation. In
`Get-ManagedIdentityClientId`, PowerShell parsed the interpolated Graph URL token
`$canonicalObjectId?` as the variable path `canonicalObjectId?`; StrictMode raised
`VariableIsUndefined` before `Invoke-AzJson` could run. A repository-wide AST audit
found exactly this one non-automatic question-mark variable path across all tracked
PowerShell. Target-only SQL control-plane readback proved public network access
remained `Disabled`, no bootstrap temporary firewall rule existed, and no database
evidence or recovery record was created. The corrected helper then completed both
exact live API/worker service-principal GETs. State records steps 1–10 `Completed`,
step 11 `Failed`, and no later step. No database initialization, Admin UI identity
or credential, runtime activation, registration, canary, Gateway key, or Registry
action followed. No SQL outbox or Service Bus message counts were captured; that
absence is not a zero-count claim, and no message data plane was accessed.

Same-source Resume would deterministically fail again, while the correction changes
the accepted source fingerprint. Preserve `a365gw14` state, accepted snapshot,
resource graph, identities, images, blueprint, and private endpoint; never
reconstruct acceptance or Resume it. Commit
`891121a6387e96f1f77eac26ef6b6cff94b79d54` braces the URL variable as
`${canonicalObjectId}` and adds both an exact executing URL regression and a
repository-wide AST guard that permits automatic `$?` but rejects ambiguous
non-automatic paths. Independent review approved the settled correction. Focused
database tests pass **5/5**. The canonical source gate discovered **454** Pester
tests: **453** passed, none failed, and one Windows-only launcher test was skipped
on macOS; it parsed **19** PowerShell files and **2** JSON contracts and compiled
all **25** Bicep templates plus **5** parameter files. Direct Release tests pass
**1,304/1,304** with the established per-project totals, the Release build has zero
warnings/errors, and format/diff checks pass. The corrected deployment-affecting
source fingerprint is
`sha256:c77ccf00013d106e440f30dda20928e65a165fd655a2eb9f88fdf17cd19a35e1`.
The next live generation is reserved as `a365gw15` in absent resource group
`rg-a365-custom-gw-phase6n`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated, and no
Service Bus message data plane was accessed in either subscription.

Fresh generation `a365gw15-dev` then used absent resource group
`rg-a365-custom-gw-phase6n`, ownership
`abea5207-95b6-439b-ac3a-a1b2b3d7f2fb`, and ACR
`acra365gw15deve7kaui`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Its accepted Plan
`sha256:f03f5e9af7d91064959d1eaead74001d1584db55058cc902e9babdc51bd6b12b`
bound configuration
`sha256:f540e7b5d51beb8dccf23cb83093245ac00fb6bea231900771d1df0cb85d2688`
and source
`sha256:c77ccf00013d106e440f30dda20928e65a165fd655a2eb9f88fdf17cd19a35e1`.
Authenticated What-If reported exactly eight `Create` predictions and no other
change type. The single Apply ran from `2026-08-30T03:25:57Z` until
`2026-08-30T03:48:13Z` (12:25–12:48 KST); no Resume ran.

Steps 1–10 completed durably. API, worker, and Admin UI image digests are
`sha256:ee760c926e2be32fe56243612b2315b1a7a3fb1f6034e56ddddcfbfac6c23881`,
`sha256:8be5395b46e4fc39070e6d405aaf7e847d5098ca26eae646cc4955477ae7b380`,
and
`sha256:30d0feb357c9f140c1ea83c35661eaab1021a164f6a47fdc7647812fc97c831c`.
The source-bound seed blueprint object/application ID is
`cd5432f4-03eb-4b66-bc5d-c9f943e75047`. Foundation, inert workload, seed
blueprint, workflow-v3 Entra, and SQL private-endpoint readbacks succeeded. Step 11
failed before the database migrator child process, firewall, SQL public-network,
schema, or database evidence path began. The sanitized state retains only the fixed
step failure, so no narrower provider root cause is claimed. No later bootstrap,
registration, Registry, key, or canary action occurred. No SQL outbox or Service Bus
message counts were captured; that absence is not a zero-count claim, and no message
data plane was accessed.

The same-source recovery Plan was
`sha256:cc615c5892406397d796701e014e88fc50e9584ef4abbca599a3b5054bac6710`.
Its first read-only What-If reported eight `Deploy` plus 29 `Ignore` predictions and
kept `applyReady=false`. A later read-only What-If reported eight `Deploy` plus 30
`Ignore` after Azure asynchronously created the Failure Anomalies smart-detector
rule. Exact target-only ARM readback found that current-App-Insights-scoped rule
enabled at Sev3/PT1M but untagged and bound to the default action group in retained
generation `rg-a365-custom-gw-phase6f`. It was neither adopted nor mutated. Preserve
`a365gw15`; edited source must never Resume it.

Commit `7cb433958fe6207ffb067cd4ce9c0340a8aa7df7` requires one contiguous,
source-bound state prefix and accepts only an independently revalidated 26-resource
inert plus four-resource SQL private-endpoint recovery graph. It explicitly owns the
Failure Anomalies rule with exact tags, current Application Insights scope, and
current project action group, and adds `Microsoft.AlertsManagement` to Doctor,
registration, and Resume provider gates. Recovery remains closed after Admin UI
deployment. Focused Experience/Azure tests pass **201/201**. The canonical source
gate discovered **469** Pester tests: **468** passed, none failed, and one
Windows-only launcher test was skipped on macOS; it parsed **19** PowerShell files
and **2** JSON contracts and compiled all **25** Bicep templates plus **5** parameter
files. Direct Release tests pass **1,304/1,304**, the Release build has zero
warnings/errors, and format/diff checks pass. Corrected deployment-affecting source
is
`sha256:cd885109f65d749f2bcf4d52297c260b93ea733cf1d3e17e436bc4fade679972`.
The next live generation is `a365gw16` / `rg-a365-custom-gw-phase6o`, only in target
subscription `6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated.

Fresh generation `a365gw16-dev` then used absent resource group
`rg-a365-custom-gw-phase6o`, ownership
`f60ba56a-4a72-4cd7-88ec-0fd745461b90`, and ACR
`acra365gw16dev2vmejs`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Its accepted Plan
`sha256:eaa1970962c9c0f0121aa4793355c607e7a894e8719a816424daed5d85a5ff67`
bound configuration
`sha256:9ef66442b1a6989bf45bcaeeda47a6870122e6e9af7552d23a619203e31d9ce3`
and source
`sha256:cd885109f65d749f2bcf4d52297c260b93ea733cf1d3e17e436bc4fade679972`.
Authenticated What-If reported exactly eight `Create` predictions, no other change
type, and `applyReady=true`. The single Apply ran from the first step at
`2026-08-30T04:29:11Z` until the failure at `2026-08-30T04:50:04Z`
(13:29–13:50 KST); no Resume ran.

Steps 1–10 completed durably. Exact ACR QuickRuns `de1`, `de2`, and `de3` all
succeeded with no extra run. The API, worker, and Admin UI digests are respectively
`sha256:f788ed6de78b463703e8f1cd42e29f7456c01786a04fc3b41499ef4bd42d68cd`,
`sha256:a9e9666638601fcb61812ab9e6e10e54042d7e794c5321dec8649cec0e952160`,
and
`sha256:73d7c03f7a018b8599af8070addf032981d2c9109ef570c0ccbe0ca7a85812c7`.
The source-bound seed blueprint object/application ID is
`cf919ca3-d180-4273-b730-cc9cc70471db`. The API managed-identity service principal
is object `324c541e-92ec-4eaa-89d3-05bca32f77d4`, client
`fdf9a655-7df0-4701-b4b1-d707ca9bff2f`; the workflow-v3 worker is object
`39f5af57-0d2f-4159-ac4e-5f50867883db`, client
`62b19841-63ff-4af0-a558-c6eae09da8ae`. Foundation, inert workload, seed
blueprint, workflow-v3 Entra, and SQL private-endpoint readbacks succeeded.

Step 11 failed before Azure SQL network, firewall, database migrator, schema, or
principal mutation. The exact root cause was PowerShell parsing of comma-terminated
Boolean expressions in `tools/apply-migrations.ps1`: all four supplied principal
arguments became one GUID-valued array element, so the fail-closed all-or-none guard
reported a partial argument set. Sanitized diagnostic
`.bootstrap/diagnostics/a365gw16-dev-20260830-045015.json` records the failure. No
database initialization, Admin UI credential, runtime activation, registration,
Registry action, Gateway key, or data-plane canary followed. No SQL outbox or
Service Bus counts were captured; that absence is not a zero-count claim, and no
Service Bus message data plane was accessed.

A later developer-only preflight diagnostic attempted to stop the corrected script
with `Set-PSBreakpoint` before its network boundary. The breakpoint did not bind,
and the child initiated the authorized temporary SQL public-network enablement. It
was immediately interrupted with `SIGINT` while still waiting for that state, before
the firewall-create or database-migrator call sites. Target-only cleanup readback at
`2026-08-30T05:03:49Z` (14:03 KST) proves the child absent, SQL server
`sql-a365gw16-dev` `Ready` with `publicNetworkAccess=Disabled`, no
`temp-a365gw-migration-*` firewall rule, and no migration evidence or network-
recovery file. Because the firewall and migrator occur only after the bounded
enabled-state wait, no database child ran. This unintended diagnostic crossing and
its proven cleanup are retained as live evidence; that breakpoint method must not be
reused.

Commit `61600ab86c721476d9b7b05121ce6a7d60e4e05a` replaces both ambiguous lists
with typed independent Boolean arrays, computes each cardinality once, and uses the
validated principal count at both downstream branches. Its regression executes the
exact source fragment under StrictMode, proves 4/4 principal and 2/2 bootstrap
bindings, and fails closed for each missing principal and a partial bootstrap
binding. The focused SQL-network gate passes **11/11**. The canonical source gate
discovered **470** Pester tests: **469** passed, none failed, and one Windows-only
launcher test was skipped on macOS; it parsed **19** PowerShell files and **2** JSON
contracts and compiled all **25** Bicep templates plus **5** parameter files. Direct
Release tests pass **1,304/1,304**, the Release build has zero warnings/errors, and
format/diff checks pass. Corrected deployment-affecting source is
`sha256:5b8184d3a05f364f98af05c78629a5772e7eafd690c479a11601e752b71e9b7d`.
Preserve `a365gw16`; edited source must never Resume it. The next live generation is
reserved as `a365gw17` / `rg-a365-custom-gw-phase6p`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated.

Fresh generation `a365gw17-dev` then used absent resource group
`rg-a365-custom-gw-phase6p`, ownership
`da283279-50ec-489e-ae7f-8b2eff8c52a6`, and ACR
`acra365gw17dev3ws4cu`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Its accepted Plan
`sha256:d1a63ffc5a1c92266b6ae60b74f436bd6369229f8e709e95a534c3726fd90dca`
bound configuration
`sha256:ca47cb9a2fec5f7aa5985d6b1570ef64251bdb23e65fe5195f0d8e12dd5db3ba`
and source
`sha256:5b8184d3a05f364f98af05c78629a5772e7eafd690c479a11601e752b71e9b7d`.
Authenticated What-If reported exactly eight `Create` predictions, no other change
type, and `applyReady=true`. The sole Apply ran from `2026-08-30T05:10:08Z` through
the failure at `2026-08-30T05:35:04Z` (14:10–14:35 KST); no Resume ran.

Steps 1–10 completed durably. Exact ACR QuickRuns `de1`, `de2`, and `de3` all
succeeded. The API, worker, and Admin UI image digests are respectively
`sha256:4937e1c0eed1e2c09b26629dad6405632cc83c44e0ba9145a5a6971ee609cd03`,
`sha256:fbd964a4157149021b29a28db04233f6e6ee5f49720d3efa212ba282b7fbe66e`,
and
`sha256:2e0024b8c1f669796a3259dcfee3f6870adf27142cd99eb881a8b21767445671`.
The source-bound seed blueprint object/application ID is
`fd5109e3-1a82-4d0a-bac0-0bae894a12f1`; the inert API and worker principal object
IDs are `20d1dc43-132b-4314-8131-e80b41ce353f` and
`b7b3edbb-5969-47bb-973a-9614285a2c01`. Foundation, inert workload, seed blueprint,
workflow-v3 Entra, and SQL private-endpoint readbacks succeeded.

Step 11 issued the reviewed temporary SQL public-network enable request, then its
bounded poll never observed `Enabled` and failed safely before firewall creation or
the database-migrator child. Activity Log records one successful
`Microsoft.Sql/servers/write` at `2026-08-30T05:31:49Z`, correlation
`90c2533b-f6ea-4ffd-b4ec-087fd6a59ce2`, and no firewall-rule write. Immediate
target-only cleanup readback proves `sql-a365gw17-dev` `Ready` with
`publicNetworkAccess=Disabled`, no `temp-a365gw-migration-*` rule, no network-
recovery file, and no `GatewayDb-*.json` migration evidence. Sanitized diagnostic
`.bootstrap/diagnostics/a365gw17-dev-20260830-053545.json` records ten completed
steps and the fixed failure. No database initialization, Admin UI credential,
runtime activation, registration, Registry action, Gateway key, or data-plane
canary followed. No SQL outbox or Service Bus counts were captured; that absence is
not a zero-count claim, and no Service Bus message data plane was accessed.

The same-source recovery What-If reported exactly eight `Deploy` plus 31 `Ignore`
predictions and kept `applyReady=false` because the reviewed state-aware boundary
contained 30 resources. Exact target-only readback identified the sole extra Ignore
as provider-managed Event Grid system topic
`sta365gw17dev3ws4cu-d3d27d40-91b3-4258-baf8-e3ca0856271a`, in the same resource
group and region and uniquely source-bound to storage account
`sta365gw17dev3ws4cu`. Its one `StorageAntimalwareSubscription` child is Succeeded
and reverse-bound to that topic. Current Microsoft documentation confirms that
Defender for Storage on-upload malware scanning automatically creates a required
same-resource-group Event Grid system topic. The exact generated topic/child names,
BlockBlob filter, and retry shape are bounded live-generation evidence rather than
a portable Microsoft naming contract; future provider drift must fail closed.

Commit `bee437fe1e2a19976565777184f70f2bbf1319ec` adds
`Microsoft.EventGrid` to the exact Doctor/Apply/Resume provider set and pins the
Event Grid CLI family to the configured subscription. Recovery independently
inventories zero or one system topic, validates an exact source/type/location/state
and bounded child contract without projecting destination URLs, fingerprints typed
absence or presence, requires exact provider/What-If parity, and accepts only the
exact 26/27/30/31 Ignore graphs. Independent security review found no remaining
actionable issue. Focused Experience, Azure, and Common tests pass **106/106**,
**116/116**, and **67/67**. The canonical source gate discovered **491** Pester
tests: **490** passed, none failed, and one Windows-only launcher test was skipped
on macOS; it parsed **19** PowerShell files and **2** JSON contracts and compiled
all **25** Bicep templates plus **5** parameter files. Direct Release tests pass
**1,304/1,304**, the Release build has zero warnings/errors, and format/diff checks
pass. Corrected deployment-affecting source is
`sha256:6cf2268084bc3dbadb692701988a900ea4b7e159bafb9a7a521cde4cfa76241b`.
Preserve `a365gw17`; edited source must never Resume it. The next live generation is
reserved as `a365gw18` / `rg-a365-custom-gw-phase6q`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` was neither selected nor mutated.

The isolated `a365gw18` generation then accepted Plan
`sha256:d5903ae8cbb0ad77ac088ef43563e904e0bc3342017df3da773f471ac3503cd0`
for resource group `rg-a365-custom-gw-phase6q`, deployment ownership
`b4934ae4-98d3-4126-a69d-0dbdd61a7fff`, configuration
`sha256:90a5a59edaf1cf69cabb46b82262e095d73b41a78526a71b62162daa2ee9abdb`,
and source
`sha256:6cf2268084bc3dbadb692701988a900ea4b7e159bafb9a7a521cde4cfa76241b`.
One Apply completed steps 1–10 and failed safely at step 11. Exact target-only
readback proved the tenant management-group policy `AzureSQL_PublicNetwork_Modify`
under assignment `MCAPSGovDeployPolicies`, with no applicable exemption, keeps the
SQL public endpoint `Disabled`. No firewall rule, migrator, schema, database
evidence, Admin credential, runtime activation, registration, Registry action,
Gateway key, canary, or Service Bus message-data-plane access followed. Preserve
`a365gw18`; its frozen source must never be resumed after the database-path edit.

The replacement candidate uses a digest-pinned, VNet-private manual Container Apps
Job, not a SQL public-network exception. It persists a safe execution-intent receipt,
authorizes exactly one retry-disabled execution, temporarily assigns only the Job
identity as the singular SQL Entra administrator, restores the exact original
administrator after the execution settles, validates exactly three evidence records
from the exact Log Analytics stream, and verifies zero SQL firewall rules plus zero
Azure RBAC/Graph application roles on the Job identity. Independent read-only
review found no remaining correctness or safety blocker. Commit
`697119d5a62d0a9db3fcdc46e2179d4955ba4bf3` froze that candidate.

The frozen local candidate gate is a zero-warning/zero-error Release build and
**1,324/1,324** direct Release tests: unit 495, Admin UI 155, local Setup 75,
observability/runtime 149, integration 92, end-to-end 106, architecture 119, and
security 133. The canonical bootstrap/runtime gate discovers **509** Pester tests:
**508** pass, none fail, and one Windows-only launcher test is skipped on macOS. It
parses **19** PowerShell files and **2** JSON contracts and compiles all **26** Bicep
templates plus **5** parameter files. `dotnet format --verify-no-changes`, `git diff
--check`, and all **58** repository-local links across **55** Markdown files pass.
Independent review also passes 324 changed-bootstrap Pester tests, 55 targeted
migrator/recovery unit tests, and four database-Job architecture tests. These are
source-only results, not deployment evidence.

Generation `a365gw19` accepted Plan
`sha256:2d2b23d350e2fa8bd5b2465b12634390ceec29fe95c055abd468a73be95edb8e`
for resource group `rg-a365-custom-gw-phase6r`, deployment ownership
`d19c1c56-6176-4ef3-8afb-d55f9bf14c68`, configuration
`sha256:90990bc4e68ccd382cd29b7b20596ce2f4ea6933827d2fc67eff104855855eb6`,
and source
`sha256:ffc24a41a53ebcd5a8bcf52b1736fb049b642f0c79e61168855bd27625bcecac`.
What-If contained exactly eight Creates and no Deletes. A raw Apply carrying an
unsupported event-stream-only flag was rejected before mutation. The valid Apply
was deliberately interrupted after provider registration while the foundation step
was `Running`. Exact target-only readback found neither the deterministic foundation
deployment nor the resource group. Same-source Resume recomputed the identical Plan
and failed closed instead of blindly replaying the missing external mutation.
Preserve `a365gw19`; edited source must never Resume it.

Generation `a365gw20` accepted Plan
`sha256:a17cf082f622342d20c6bd2bd20e153175bca50768567ed9f0320df49776271e`
for resource group `rg-a365-custom-gw-phase6s`, deployment ownership
`51368948-86e2-4bd4-9bec-9acac27937a2`, configuration
`sha256:a4fdc29b6fabb3e3b7328a38a3e7e84807c9df351b44083c87c0efef4785a24e`,
and the same source fingerprint. What-If again contained exactly eight Creates and
no Deletes. Apply was deliberately interrupted at Azure authentication after
Prerequisites; exact-fingerprint Resume then completed steps 1–10. Foundation
deployment `a365gw-a365gw20-bootstrap-foundation-dev` succeeded under correlation
`76f69efb-d2e5-42ee-9e73-e894e914cc2e`; all four ACR QuickRuns succeeded in
`acra365gw20devqprwi7`. Inert deployment
`a365gw-a365gw20-bootstrap-inert-dev` succeeded under correlation
`f2c3ecab-7f64-431f-83dc-b30e3f0de907`, followed by the seed blueprint,
workflow-v3 Entra configuration, and SQL private endpoint. The private-endpoint
deployment succeeded under correlation `8c28b234-2be9-479c-872e-1c457e567e6e`.

Step 11 deployed dormant manual Job `job-a365gw20-db-init-dev` through deployment
`a365gw-a365gw20-bootstrap-database-job-dev`, correlation
`7bc4f9a9-f68f-4692-b9a9-c399fa0ac6b5`. Its exact post-deployment validator then
failed because Azure returned location `Korea Central` for configured
`koreacentral` and returned absent optional arrays as provider `null`. The durable
receipt contains the execution intent but no Job principal, deployment verification,
administrator-swap intent, Job-start intent, execution, evidence recovery,
administrator restoration, or completion. Exact live readback proves zero Job
executions and the original singular SQL Entra administrator remains unchanged.
No database schema, Admin credential, runtime activation, registration, Registry
action, Gateway key, canary, or Service Bus message-data-plane access followed.
Preserve `a365gw20`; its immutable accepted source must never be altered or rebound.

Commit `dc25132` normalizes only equal ASCII-alphanumeric Azure region display forms
and actual null collection entries; every non-null unexpected entry remains visible
to exact cardinality/value checks. Independent review found no fail-open and
confirmed that a fresh source generation is required. The zero-warning/zero-error
Release build and all **1,324/1,324** direct Release tests pass. The canonical gate
discovers **512** Pester tests: **511** pass, none fail, and one Windows-only launcher
test is skipped on macOS; it parses **19** PowerShell files and **2** JSON contracts
and compiles all **26** Bicep templates plus **5** parameter files.

Generation `a365gw21` accepted Plan
`sha256:7a5f0d11838a9961bc85e890c726f40764bfad1e713b9b6f92dd417359033855`
for `rg-a365-custom-gw-phase6t`, deployment ownership
`bf8fd3a9-86e9-41ff-978a-dc3e4654c944`, configuration
`sha256:31e9d1b47e30eb269408d937e3306e0b4e47262a7c5fe916e928c6491a8953a0`,
and source
`sha256:db5c4eee6528c133c19ad1859708e667594e82d12ba3aff558b73c928ff6312d`.
What-If contained exactly eight Creates and no Deletes. Apply completed steps 1–10.
Foundation deployment `a365gw-a365gw21-bootstrap-foundation-dev` succeeded under
correlation `56a563eb-1a48-4ae6-ae31-0acd9e4587dc`; four immutable QuickRuns
succeeded in `acra365gw21devp7in2u`; inert deployment
`a365gw-a365gw21-bootstrap-inert-dev` succeeded under correlation
`be55cb4b-1970-4902-8fed-94c594206e10`.

Step 11 deployed and exactly validated dormant manual Job
`job-a365gw21-db-init-dev` through deployment
`a365gw-a365gw21-bootstrap-database-job-dev`, correlation
`7bae8412-e580-437b-ad29-38d3a1c04ed8`. The receipt recorded its principal,
deployment verification, SQL-administrator swap, and one durable start intent.
Azure Activity Log correlation `bbca4fbf-1b0f-4fc2-9802-442faa92a1c5` reported
`ContainerAppImageRequired`: the environment-only start override replaced the full
template and omitted its required image. Exact target-only readback proved zero Job
executions and no database schema/evidence/completion. A separately bounded recovery
restored the original singular SQL Entra administrator exactly, re-proved public
network access `Disabled` and zero firewall rules, and terminated only the local
waiter. Step 11 remains `Running` in immutable state; preserve the partial receipt
and live recovery truth. No Admin credential, runtime activation, registration,
Registry action, Gateway key, canary, or Service Bus message-data-plane access
followed.

Current Microsoft documentation states that any Job start override replaces the
entire execution template. The working-tree correction binds the existing safe
intent into the reviewed digest-pinned template, revalidates the Job plus zero
executions immediately before temporary SQL authority, and issues one no-override
start with only the exact resource group and Job name. Its complete local gate is a
zero-warning/zero-error Release build and **1,325/1,325** direct Release tests: unit
495, Admin UI 155, local Setup 75, observability/runtime 149, integration 92,
end-to-end 106, architecture 120, and security 133. The canonical source gate
discovers **516** Pester tests: **515** pass, none fail, and one Windows-only launcher
test is skipped on macOS; it parses **19** PowerShell files and **2** JSON contracts
and compiles all **26** Bicep templates plus **5** parameter files. Focused
database/final-verification/experience coverage passes **173/173**, the Job
architecture tests pass **5/5**, and format/diff checks pass. It remains source-only
until frozen and deployed; independent read-only review found no remaining
correctness or safety blocker. Never Resume `a365gw21` with edited source. The next
live generation is `a365gw22` /
`rg-a365-custom-gw-phase6u`, only in target subscription
`6f6ae863-dcb7-456f-a7f0-d6f9887cfb76`. Protected subscription
`95bedc30-f6ac-481b-a3a6-588d2883c216` remains outside the proof.


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

This retained source checkpoint is superseded by the 2026-08-30 `a365gw18` policy
evidence and private database-Job correction above. Its public-IP migration text is
historical and must not be used for the next generation.

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
6. Continue the disposable clean-development-subscription proof in new isolated
   generation `a365gw22` / `rg-a365-custom-gw-phase6u`. Preserve `a365gw11`,
   `a365gw12`, and `a365gw13` with steps 1–6 complete and step 7 `Failed`, and
   preserve `a365gw14`, `a365gw15`, `a365gw16`, `a365gw17`, and `a365gw18` with
   steps 1–10 complete and step 11 `Failed` before database migration. Their succeeded
   resources and GET-only diagnoses do not authorize Resume after any validator or
   helper source change. Preserve `a365gw19` at a nonterminal foundation checkpoint
   with no exact ARM deployment/resource group, preserve `a365gw20` after dormant
   Job deployment but before any SQL mutation or Job execution, and preserve
   `a365gw21` with its failed durable start intent, zero executions, exact manual SQL
   administrator restoration, and immutable `Running` step-11 state. None may
   consume edited source. Capture the fresh generation's safe state, template
   ownership/source-fingerprint outputs, accepted-source snapshot provenance, image
   digests, exact Key Vault scopes, private database-Job execution and original SQL
   administrator restoration, zero-firewall empty-schema initialization, final
   preflight, authenticated Admin sign-in, one real
   registration through `Active`, one bounded data-plane canary, and one Gateway-key
   revocation before marking the minimal-profile clean-subscription path
   live-proven. Purview and Prompt Shields remain disabled and unclaimed for this
   proof.

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
