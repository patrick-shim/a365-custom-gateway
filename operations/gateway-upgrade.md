# Versioned in-place Gateway upgrade

[`gateway-upgrade.ps1`](gateway-upgrade.ps1) is the retained v2 maintenance
orchestration: Package, Prepare, Plan, Build, Execute, Verify and compatible Rollback,
with a separate original-only SQL administrator compensation mode. It does not
invoke Setup, Resume, recovery commands or the old database initialization job.
The older [`gateway-maintenance.ps1`](gateway-maintenance.ps1) is only a v1
baseline/contract scaffold, not an execution alternative.

Supporting files and related Azure resources were deliberately removed. This
guide describes the retained lifecycle contracts, not a current deployment or a
fully revalidated runnable workflow. `tools/Gateway.Setup`,
`tools/Gateway.DatabaseMigrator`, `tools/Gateway.LiveVerification` and the former
`tests/` projects are absent. Restore and validate those prerequisites before
using a release workflow. Historical `gw0911g` repairs are not current steps.
[MILESTONES.md](../MILESTONES.md) is the sole completion and acceptance record.

## Authority and evidence

Follow [AGENTS.md](../AGENTS.md) for the selected target and existing user
authorization. Do not request authorization again merely because an older guide
assumed it expired. The source-bound review and Plan bindings below are application
operational controls; they do not establish project milestone completion.

Source builds or local tests alone do not authorize Azure mutation. For an
eligible preserved environment, the retained sequence is:

1. **Package** allowlisted working-tree source. Missing clean build prerequisites
   may come from the explicitly selected retained packaging baseline. Their exact
   hashes and origins are recorded; main-worktree deletions are never restored.
2. **Prepare** an isolated local build and obtain the compiled EF-model
   fingerprint. The complete executable bundle, dependencies and runtime
   configuration are pinned, not just the entry DLL.
3. Generate a read-only **Plan**. It freshly invokes the corrected canonical
   verifier against the actual preserved state. Historical Failed verification
   stays Failed; diagnostic reports are not accepted as authorization receipts.
4. Obtain independent GPT-6 Astra source review and generate the reviewed
   **Build Plan**. Approve its exact returned fingerprint.
5. **Build** source-bound ACR artifacts and the signed Windows executor package.
   Build creates only the owned coordination container/lease and ACR artifacts,
   not capability resources, SQL changes, identities or application revisions.
6. Put the exact returned API/worker/Admin/migrator digests into the upgrade
   request and generate a new **deployment Plan** bound to the artifact bundle.
   Approve that exact fingerprint before **Execute**.
7. **Verify** performs fresh maintenance readback. It never manufactures missing
   bootstrap completion or reruns a private migration.

The independent review JSON must contain `schemaVersion: 1`,
`decision: "ApprovedForMaintenance"`, `reviewerModel: "gpt-6-astra"` and the exact
`candidateFingerprint` and `sourceFingerprint`. This is an operator-provided
review record, not a cryptographic signature or an automatically generated
approval. Never create it to represent review that did not occur.

Each v2 Plan also records `authorizedOperator`: the exact tenant Member object
ID and the identical automation-application owner object ID. Plan creation reads
the authenticated identity; execution freshly rechecks it before mutation.
A different Member is not interchangeable with the approved operator. The
checks do not log in or switch accounts; changing the operator requires a new
reviewed Plan fingerprint.

ARM credentials select the exact approved subscription and independently check
the returned tenant before sending HTTP. Azure CLI does not accept simultaneous
subscription and tenant selectors for `account get-access-token`; this check
preserves both bindings without that invalid invocation or logging tokens.

## Commands

These command examples explain the interface once its missing prerequisites and
target eligibility have been verified. They do not authorize resuming deliberately
deleted resources. Outputs are under the main checkout's `.maintenance` directory;
retained source/state/configuration are read-only inputs.

```powershell
.\operations\gateway-upgrade.ps1 -Mode Package `
  -PackagingBaselineRoot '<retained clean source>'

.\operations\gateway-upgrade.ps1 -Mode Prepare `
  -CandidateReceiptPath '<package provenance.json>' `
  -ExpectedCandidateFingerprint 'sha256:<candidate fingerprint>'

.\operations\gateway-upgrade.ps1 -Mode Plan `
  -StatePath '<original state.json>' -ConfigPath '<original config.json>' `
  -RequestPath '<separate upgrade request.json>' -ValidationPath '<local validation.json>' `
  -ReviewPath '<independent source review.json>'

.\operations\gateway-upgrade.ps1 -Mode Build `
  -StatePath '<original state.json>' -ConfigPath '<original config.json>' `
  -PlanPath '<approved Build Plan>' -ExpectedPlanFingerprint 'sha256:<approved Build Plan fingerprint>'
```

Core-to-Full installation uses the v1 request structure documented in
[gateway-maintenance.md](gateway-maintenance.md).
Set `database.targetModelFingerprint` to Prepare's output. If the physical
post-migration fingerprint is not yet known, set `targetSchemaFingerprint` to
`""`: the private migrator must match the approved compiled model and then
records the actual physical fingerprint. Include every reviewed required SQL
script in migrator order with its exact checksum. Do not freeze checksums while
another owner is editing SQL or mappings.

### Source-only maintenance of an installed Full deployment

Use request **schemaVersion 2**, **mode `SourceOnlyFull`** for an already-Full,
19-stage completed/Passed bootstrap with an Installed `freshPurviewExecutor`.
Other recovery/repair variants, partial capability baselines, historical failures,
resource adoption, configuration changes, SKU changes and schema changes are
rejected. The normalized configuration fingerprint must equal the original
accepted fingerprint. Full evidence, executor ownership, identities, package,
certificate and endpoints remain bound to that original source; they are never
relabeled as the new source.

Baseline verification runs the current reviewed verifier code against the
independently hash-checked original accepted snapshot for executor assets. The
original snapshot is resolved from the preserved ownership and accepted Plan,
never from a caller-supplied replacement path. The prior source context is
restored even on failure; neither state nor original assets are rewritten.
The complete read-only baseline child has a bounded 30-minute deadline because
the installed Full verifier performs sequential Azure/Graph/private-executor
readbacks. Expiry still kills its process tree and accepts no result. This
does not extend the independent 600-second live cutover boundary or authorize
any partial verification, mutation retry or lease break.

The request otherwise retains the v1 field names:

```json
{
  "schemaVersion": 2,
  "mode": "SourceOnlyFull",
  "releaseId": "full-source-fix",
  "target": {
    "subscriptionId": "<original subscription GUID>",
    "tenantId": "<original tenant GUID>",
    "resourceGroupName": "<original rg-project-environment>",
    "location": "<original location>",
    "projectName": "<original project>",
    "environment": "dev",
    "deploymentOwnershipId": "<original ownership GUID>"
  },
  "capabilities": {
    "promptShields": { "enabled": true, "sku": "F0", "acceptPaidUsage": false },
    "purview": { "enabled": true, "executorSku": "B2", "acceptPaidHosting": true }
  },
  "images": { "api": "", "worker": "", "adminUi": "", "databaseMigrator": "" },
  "database": {
    "name": "GatewayDb",
    "currentSchemaFingerprint": "sha256:<original physical fingerprint>",
    "targetSchemaFingerprint": "sha256:<same original physical fingerprint>",
    "targetModelFingerprint": "sha256:<Prepare compiled-model fingerprint>",
    "scripts": [],
    "rollbackStrategy": "RetainExpandedSchema"
  },
  "acknowledgeHistoricalVerificationFailure": false
}
```

Use the actually installed F0/S0 and B1/B2 values, not this example as permission
to resize. `acceptPaidUsage` is false for existing F0 and true for existing S0;
`acceptPaidHosting` acknowledges retained Basic hosting, not new installation.

`-Mode ValidateRequest -StatePath ... -ConfigPath ... -RequestPath ...` performs
**local-only** request, retained-evidence, scope and SQL-manifest admission. It
does not authenticate, validate the compiled model, freeze a candidate, perform
live verification, issue a Plan, or permit Build/Execute. Its false readiness
flags are intentional. Complete the normal Package/Prepare/genuine independent
review/Plan approvals before mutations.

Source-only execution preserves the existing Content Safety account and SKU,
Windows plan/site/principal, private network, executor application/role, automation
application/certificate, queues and permissions. It does not install capabilities,
grant the worker certificate access, create a new executor, or change F0 to S0.
The one reviewed executor deployment writes **only existing appsettings**, changing
the package URL, manifest digest and execution-source/package binding. The complete
remaining settings and protected workload environments are retained and rechecked.
The publisher and private verification job are source-bound maintenance jobs,
not replacement capability resources.

The private SQL manifest uses version 2 with **zero scripts**. It verifies the
compiled model and exact principals before and after its serialized preservation
window, independently observes the held platform/durable work boundary, compares
all original registration and credential columns, retains the initialization
marker and Full capability facts, and emits the existing versioned upgrade receipt.
Its intent/commit/receipt evidence is in private blob storage; no bootstrap SQL
initialization or generic prepare/DDL runs. Incomplete outcomes never replay, even
when the intended DDL set was empty. The original Full capability projection is
retained rather than fabricating a Core-to-Full preparation receipt. Joint runtime
readback requires both that projection and the new source-bound database receipt.
Rollback still requires independently reviewed compatible immutable API/worker/Admin
images; it retains the upgraded executor package, schema, rows and evidence.

After Build, update only the **separate request** with its returned digests.
Repeat Plan with `-ArtifactBundlePath '<returned artifacts.json>'`, review its
resources/roles/costs and approve the new fingerprint. Run Execute or Verify with
the same original state/configuration and that exact Plan.

## Frozen-candidate validation

Resolve independent review findings and settle every source/SQL/model writer
before freezing the replacement candidate. Package the settled source once;
recompute all migration checksums from those candidate bytes and verify their
order against the compiled migrator manifest. Never overwrite an older candidate,
validation receipt or Plan to represent newer source.

Prepare expects the candidate migrator to compile and emit its target-model
fingerprint and executable-bundle evidence. The migrator source is currently
absent. After restoring it, Prepare still does **not** establish that application
builds, tests or executor packaging passed. Separately perform fresh API,
worker and Admin builds, the restored regression suites, real local
migration-runner tests and signed executor-package validation from isolated
copies of that same candidate. Keep source/package/test-result bindings explicit.
Tests using the current main checkout or earlier binaries are scoped development
evidence, not frozen-candidate evidence.

The canonical Windows package publisher disables SDK `web.config` rewriting with
`IsTransformWebConfigDisabled=true` and checks that the published configuration is
byte-for-byte identical to the reviewed executor source file. An absent or
rewritten IIS configuration fails packaging before a receipt is issued.

After this validation, generate a fresh independent baseline and review-only v2
Plan. Build and Execute remain blocked until their respective exact Plan
approvals. A source, model, checker or artifact change invalidates the earlier
binding and requires a new candidate/Plan as applicable; never relabel preserved
bootstrap verification or use a diagnostic report as authorization.

## In-place execution

Execution uses both a local deployment-owner lock and the documented ARM
`Blob Containers - Lease` API on an owned private-storage container. The lease
is infinite: unknown outcomes retain it rather than admitting a concurrent
upgrade. Released leases are reconciled through cloud state before acquisition;
no lease is automatically broken.

Every external mutation has a create-only intent before dispatch. Existing
intents permit exact read-only reconciliation, never blind create/rebuild/replay.
Completed ACR images and publisher contexts are reused only after their exact
source, run, digest and file manifests pass verification.
Maintenance Build and artifact verification explicitly select the narrow
`MaintenanceV1` tag contract in the real ACR readers. Default bootstrap reader
guards remain unchanged; arbitrary tags are not accepted.
Graph pre-grant validation consumes the shared immutable
`CapabilityPreparationContract.GraphApplicationRoleIds` from the reviewed
migrator bundle through its read-only `capability-graph-role-id` lookup. The
complete local bundle is checked before a fresh subprocess reads the mapping;
unknown names or conflicting provider IDs abort before grant intent. This lookup
does not access SQL or Azure, change receipt/options JSON, or include the separate
Exchange application permission.

The SQL-job behavior below is the contract expected by the retained orchestration.
Because the migration runner source is absent, its internal transaction, manifest
and reconciliation behavior must be re-established and tested before this path
can be accepted as runnable.

- In the v1 Core-to-Full route, Content Safety is **S0**, uses the existing API managed identity and disables
  local authentication. Its endpoint remains public with Entra authentication;
  the tool does not claim private-endpoint deployment.
- Purview uses the exact owned automation application/certificate, reviewed
  Graph and Compliance Administrator authority, isolated runtime identity,
  dedicated protection queue and private **Windows B1** executor. Worker access
  to the certificate is secret-scoped, never vault-wide.
- A new, one-shot private Container Apps migration job uses its system identity.
  The original SQL administrator is temporarily delegated to that exact job and
  restored before acceptance. Completed-job reconciliation does not redelegate
  after restoration.
- The job's complete fixed command, arguments, environment, secret/identity,
  registry, resource and execution settings are checked before administrator
  delegation and start. Receipt acceptance also requires an exact execution
  template readback, not only the job image or a successful execution status.
- SQL keeps the original initialization marker untouched. Separate create-only
  private Blob intent/receipt history binds Plan/source/scripts/model, original
  marker and preserved registration/credential data. Existing rows are protected
  under a bounded preservation transaction; ambiguous outcomes do not authorize
  SQL replay.
- Executable admission requires all four current capability/configuration/runtime/
  prompt-context migrations in registered order with exact raw-byte checksums.
  Source review and image approval cannot override a missing migration.
  A separate create-only `commits/<planhash>.json` checkpoint records known SQL
  commit before post-verification. It is not a completion receipt. Failed
  post-verification leaves committed schema and no verified receipt; SQL is not
  replayed or down-migrated. If commit acknowledgement/checkpoint persistence is
  ambiguous, the retained intent still forbids replay and does not claim rollback.
- Before any schema statement, that private job independently reads all three
  effective capability rows from SQL. It checks deterministic row identities,
  original deployment/source, coherent actual readback timestamps, exact Core
  capability states and identifiers. The shared canonical facts JSON and hash
  are retained in the create-only intent and DB receipt. Missing, foreign,
  partial or unprovable facts abort before schema/runtime changes.
- The API checks the original database boundary **and** the pinned upgrade
  receipt. Prepared capability projection uses the shared receipt/history
  contract and preserves original capability facts.
- Worker/API/Admin updates preserve endpoint identities and Key Vault references.
  API revision readiness uses database attestation before traffic promotion.
  The upgraded worker remains at minimum one replica for observable startup.

S0 usage, Windows B1 hosting, ACR builds, private networking/storage/logging,
Purview licensing/usage and the warmed worker can incur charges. The generated
Plan repeats these boundaries; review acknowledgements are not spending caps.

## Compatible rollback

Rollback never performs a down migration, restore-over-live, queue purge or
Registry replay. Supply `-RollbackContractPath` when generating the approved
deployment Plan. Its `strategy` must be `RetainExpandedSchema`, queue must remain
`gateway-provisioning-v3`, both `capabilityPreparationContractVersion` and
`databaseUpgradeContractVersion` must be 1, and its `modelFingerprint` must match
the current verified expanded database.

The contract lists exact `images` for `api`, `worker`, `adminUi` and an existing
`reviewEvidenceReference` with `reviewEvidenceFingerprint`. That review must
declare `decision: "BackwardCompatible"`, `reviewerModel: "gpt-6-astra"`, the same
images/model, and nonempty checksummed `testEvidence` records (`path`, `sha256`).
No compatibility is inferred for the original Core images. Without appropriate
review, Rollback fails before code promotion.

The private rollback job uses the explicit read-only `upgrade-observe` dispatch,
not `upgrade`. It requires the existing verified upgrade receipt/intent/commit
chain and a bounded observation input tied to the same Plan, candidate source,
receipt and current model, plus the exact compatible images and hashed independent
review. Local orchestration also verifies the referenced test files before
dispatch. The job does not create a missing receipt or apply SQL.
The expected compatibility-review fingerprint and rollback images are included
in the approved SQL manifest and its immutable intent/commit binding before the
upgrade. A self-consistent replacement review/image set cannot be supplied later
under the same Plan. An upgrade with no such reviewed rollback anchor does not
silently acquire rollback authority.

First-upgrade classification remains strict about unclassified additive data.
Compatibility-bound rollback uses a separate current-contract classifier:
valid completed evaluations are retained whether consumed, expired or still
available to the compatible reader; completed configuration and runtime-test
metadata are retained rather than cleared. Completed inline runtime tests use
their actual zero-worker-step contract and known completed result, not a fabricated
legacy eight-step workflow. Earlier completed `Partial` batches are retained when
a terminal suite result matches their suite/configuration/mode; known completed
simulation submissions are classified separately from enforcement certification.
In-flight, retryable, malformed or unknown outcomes
still block. Historical certification expiry is not evidence of in-flight work;
this observation never grants current policy readiness or consumes a receipt.

All three workload baselines are captured together before any promotion.
Rollback checks each workload against its original or exact attempted deployment.
An untouched component is skipped only when the independently approved rollback
image/environment already match that baseline and fresh readback is healthy.
An intent with an unchanged baseline is not proof the attempted update settled.
An ambiguous component stays unverified while independently safe components can
be rolled back; an incomplete result is recorded and surfaced as failure, never
as successful rollback. The low-level workload dispatcher is private; rollback
is exposed only through the compatibility-guarded v2 pipeline.

The prompt-receipt context migration deliberately leaves historical receipts
unbound. Those receipts cannot authorize later protected ingestion; clients must
reevaluate with the current protection configuration. A compatible release must
coordinate every API/protection writer so that old writers cannot alter settings
without advancing the protection revision. Additive columns alone do not prove
mixed-version safety. Require reviewed writer draining/promotion and rollback
evidence before deployment; do not promise uninterrupted protected ingestion
with an old writer still active.

Data-plane idempotency keeps one additional unpooled SQL session/application
lock per active operation during provider I/O. Context validation, receipt
consumption and persistence use a separate short transaction on the normal
scoped connection; the provider call is not inside that transaction.
Before promotion, budget the additional sessions across all API replicas,
including provider latency and lock waits, alongside normal pooled connections.
Verify target SQL capacity and admission/draining behavior; unchanged SQL
permissions or an additive schema do not establish capacity headroom.
Do not increase the SQL SKU or connection limits without explicit Plan review.

Owned staged-Blob compensation is permitted only after a known precommit
rejection and confirmed rollback. An ambiguous commit outcome must retain the
artifact for bounded reconciliation, not authorize automatic deletion.

## Required migration validation

The migration runner and former test projects are absent. Historical references
to `MaintenanceUpgradeRunnerSqlTests`, opt-in environment variables, a particular
Git baseline or past test outcomes are not current validation. M1 restores the
minimum runnable source and tests; M5 validates the frozen release candidate.

The restored test path must exercise the real ordered SQL scripts against an
independently established prior schema with synthetic registrations, credentials
and receipts. It must check original-marker preservation, transaction rollback,
unknown outcomes without replay, and a committed migration whose subsequent
verification fails without falsely claiming rollback or successful completion.
The exact schema/model comparison also needs equivalent and mismatched catalog
cases. Source, checksums, model and executable artifacts must remain bound to the
same candidate.

Local SQL testing cannot establish Azure managed-identity, private-DNS,
runtime-principal or Blob transport behavior. Those require the separately scoped
live acceptance in M6. Local results must not be presented as provider receipts.

## Acceptance boundary

`MaintenanceInfrastructureVerified` is not Purview policy propagation or a
runtime verdict. The tools do not select SITs, alter user policies, manufacture
tenant consent or bypass interactive authentication. Settings-owned tenant
connection, policy configuration and independently approved runtime tests still
require actual Microsoft 365/Purview access and licensing. Report such failures
as observed external blockers; resource existence or mock success is not proof.

### Runtime-sample capture validation

Before approved live sample tests, verify both reviewed source behavior and
actual deployed capture configuration. Source-level logging suppression alone
does not prove that HTTP middleware, reverse proxies or APM agents omit bodies.

- Confirm samples are excluded from Gateway SQL, outbox messages, Blob objects,
  application/platform logs, circuit/session storage and telemetry payloads.
- Inspect only an explicit nonsecret allowlist of relevant HTTP logging, request
  tracing, detailed-error, reverse-proxy and APM body-capture settings. Never dump
  complete environment variables, application settings or secrets into evidence.
- Independently verify the effective deployed values and exact source/artifact
  binding; an absent configuration key must not silently be interpreted as a
  safe disabled setting when its runtime default is unknown.
- After an explicitly approved synthetic canary and bounded ingestion wait, use
  aggregate-only log queries. Retain counts, time windows and opaque test
  references, not sample text or matching log bodies. Absence of matches is
  supporting evidence only, never the sole proof of noncapture.
- Treat Microsoft Purview's upstream processing and retention as a separate,
  disclosed provider boundary. Do not claim zero upstream retention.

Record unknown or unavailable capture configuration as an open acceptance
blocker rather than substituting a clean source test or zero-match query.

No current deployment or acceptance is asserted here; use MILESTONES.md for the
actual verification status after the deliberate reset.

The prepared-capability builder consumes the independently observed facts from
the verified private DB receipt, not a guessed timestamp, retained bootstrap
snapshot, or caller-declared prior-facts JSON. The effective capability table is
expected to change atomically under the API store lock; its original/prior facts
remain in immutable preparation history. Thus byte-identical legacy projection
rows or old-code restart/rollback compatibility are never assumed.

## Separately reviewed pre-cutover abort

`AbortPlan`, `AbortExecute`, and `AbortReconcile` provide a deliberately narrow
`AbortBeforeCutover` lifecycle. It is **not** Rollback or successful maintenance
acceptance. It supports only an already approved executable `SourceOnlyFull`
Plan whose execution directory contains exactly:

- `lease.json`
- `actions\coordination-container\intent.json`
- `actions\coordination-container\result.json`

Any additional file/directory, partial record, cutover evidence, workload change,
SQL delegation, planned mutation job or Plan-scoped ARM deployment rejects this
abort. Both queues must still be Active, the original SQL administrator must be
unchanged, and the current canonical read-only bootstrap verifier must prove the
original healthy deployment. Azure resource identity comparisons are ordinal
case-insensitive; the recorded source, Plan, operator and evidence fingerprints
are not relaxed.

### Distinct authority, not reuse of the deployment approval

The original executable Plan, its candidate, local build closure, artifacts,
review, state/configuration and three checkpoint files are separately validated
and hash-bound. A fresh child validates the old Plan using a content-addressed
**original-byte verifier bundle**, not patched validators masquerading as the old
source. This bundle copies exactly the old Plan's verifier manifest. The sole
packaging omission supported is `tools\_common.ps1`, which may be copied from the
current checkout only when its bytes match the old Plan's recorded hash. No
original candidate, Plan or accepted snapshot is altered.
The new abort authority records each verifier file's original path, SHA-256,
copy origin and resolved source path separately from the unchanged old manifest;
no provenance file is inserted into the original-byte verifier bundle.

Canonical baseline and operator code in the actual checkout must still match
the original verifier manifest. The new dispatch/execution/abort driver code,
its dependencies and the PowerShell executable are pinned under **new abort
authority**. The original Member/operator, automation owner, local machine/SID,
lease-file hash and exact owned private coordinator must match. A separate
genuine GPT-6 Astra lifecycle/source review and exact Abort Plan approval are
required before either lease write.

ARM JSON is parsed with the same strict literal-preserving reader used for
maintenance evidence. Date-looking environment strings retain their exact
spelling and offset instead of becoming PowerShell DateTime values. New Abort
Plans and journal records are read back and fingerprint-checked after writing;
a failed serialization round trip never yields approval or a next lease action.

1. Settle the abort driver changes; retain the original candidate and receipts.
2. Generate a **read-only draft**:

   ```powershell
   .\operations\gateway-upgrade.ps1 -Mode AbortPlan `
     -OriginalPlanPath '<original deployment Plan>' `
     -ExpectedOriginalPlanFingerprint 'sha256:<original approved Plan>' `
     -StatePath '<original state>' -ConfigPath '<original config>'
   ```

   It outputs an `abortPlanPath`, `abortPlanFingerprint`, `authorityFingerprint`
   and `driverFingerprint`, with `executionSupported: false`. It runs local
   validation and fresh provider **reads**, but does not renew/release a lease.

3. Obtain a real independent review of this lifecycle and its complete authority.
   Supply a separate JSON review record with exactly:

   ```json
   {
     "schemaVersion": 1,
     "decision": "ApprovedAbortBeforeCutover",
     "reviewerModel": "gpt-6-astra",
     "authorityFingerprint": "sha256:<draft authority>",
     "originalPlanFingerprint": "sha256:<original deployment Plan>",
     "driverFingerprint": "sha256:<new abort driver manifest>",
     "evidencePath": "<absolute path to genuine independent review evidence>",
     "evidenceSha256": "sha256:<review evidence file bytes>"
   }
   ```

   This record is not a cryptographic reviewer signature. Never manufacture one
   from a code change, diagnostic result or earlier maintenance approval.
   Review and evidence files must be inside the workspace (normally
   `.maintenance\reviews`); a genuine report may be copied there byte-for-byte.

4. Repeat `AbortPlan` with `-ReviewPath '<abort-specific review.json>'`.
   Fresh reads generate a **new** exact Abort Plan fingerprint. Review and
   explicitly approve that fingerprint, then:

   ```powershell
   .\operations\gateway-upgrade.ps1 -Mode AbortExecute `
     -AbortPlanPath '<reviewed Abort Plan>' `
     -ExpectedAbortPlanFingerprint 'sha256:<separately approved Abort Plan>'
   ```

The original deployment-owner local lock remains exclusive throughout execution.
A create-only abort journal under `.maintenance\abort-state\<original Plan hash>`
blocks normal Build/Execute/Rollback/restoration and lease reacquisition for that
old Plan from the moment abort admission starts, including partial/empty journal
directories. It is permanent supersession evidence, not a disposable lock file.

Execution verifies the original live boundary, writes abort/renew intent, and
issues **one Renew with the exact retained lease ID** to prove possession. After
acknowledgement it independently rechecks the original live boundary and current
authority, writes release intent, and issues **one Release of that same ID**.
There is no Acquire, Break, Change, new lease ID, SQL operation, application
deployment, resource deletion, fake `$completed`, or private release-helper
shortcut. `Available`/`Unlocked` readback is required before the distinct
`AbortBeforeCutoverVerified` terminal record.

An interrupted or uncertain write is **never replayed**, including Renew.
Use only the existing exact reviewed Abort Plan for bounded read-only provider
reconciliation:

```powershell
.\operations\gateway-upgrade.ps1 -Mode AbortReconcile `
  -AbortPlanPath '<same reviewed Abort Plan>' `
  -ExpectedAbortPlanFingerprint 'sha256:<same approved Abort Plan>'
```

Reconciliation may append local terminal evidence only when release intent and
the completed renewal chain already exist and the original healthy boundary
plus `Available`/`Unlocked` are freshly observed. If still leased, foreign,
partial, drifted or unclassified, it fails closed without any lease write.
Even a recorded Renew result without release intent does not authorize automatic
continuation in a later invocation. Existing terminal evidence is returned as
historical evidence, not a claim about a later lease held by another Plan.

After verified abort, preserve all old artifacts/receipts/journals. Generate a
new candidate, genuine source review and separately approved maintenance Plans
for the corrected release. The old Plan must never be reacquired or resumed.

## Original-only SQL compensation (separate from abort)

If an interrupted migration left its exact job identity as SQL administrator,
`-Mode RestoreSqlAdministrator` accepts only the previously approved Plan and
its retained pre-mutation delegation evidence:

```powershell
.\operations\gateway-upgrade.ps1 -Mode RestoreSqlAdministrator `
  -PlanPath '<previously approved deployment Plan>' `
  -ExpectedPlanFingerprint 'sha256:<previously approved fingerprint>'
```

This path does not load candidate binaries or require candidate/configuration
availability. It independently matches the original restore tuple, exact owned
migration job/principal and current administrator, and can restore **only** that
original administrator. It cannot redelegate, execute SQL, promote workloads,
continue an upgrade or break its cloud lease. Normal execution retains all source
and artifact checks.

Protected workload baselines also cover non-maintenance-owned environment
settings, including tenant, audience, identity and connection configuration.
Rollback cannot adopt changes to those settings from a newly read snapshot.

## Local runtime prerequisite

The retained executor package contract requires Microsoft-signed PowerShell
**7.6.5** exactly and ExchangeOnlineManagement **3.10.1**. The Build workflow must
use a matching validated installation; a newer runtime is not silently accepted
in place of the pinned dependency.

Do not assume a project-local portable runtime, historical download or earlier
prerequisite result survived the reset. Re-establish its provenance, signature,
version and package compatibility during release preparation. Runtime discovery
and local validation do not authorize a Build or deployment mutation.
