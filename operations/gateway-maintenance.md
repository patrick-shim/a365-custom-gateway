# In-place Gateway maintenance, contract v1

This v1 public CLI is a **baseline/contract scaffold, not an execution alternative**.
The retained approval-bound maintenance orchestration is v2
[`gateway-upgrade.ps1`](gateway-upgrade.ps1), documented in
[gateway-upgrade.md](gateway-upgrade.md). This document retains the shared request
contract and explains the v1 baseline; it does not describe a second deployment path.
The v1 CLI is not an installer, Resume, recovery workflow, or deployed capability. It preserves the original bootstrap state,
configuration, accepted source, SQL initialization marker, identities, endpoints,
registrations and keys. No existing resources are replaced by this v1 scaffold.

Supporting files and related Azure resources were deliberately removed.
`tools/Gateway.Setup`, `tools/Gateway.DatabaseMigrator`,
`tools/Gateway.LiveVerification` and the former `tests/` projects are absent.
The complete installation and maintenance paths are not yet revalidated runnable.
This guide describes retained contracts for an eligible preserved deployment;
it does not identify a current target or direct resumption of deleted resources.
[MILESTONES.md](../MILESTONES.md) is the sole completion and acceptance record.
Follow [AGENTS.md](../AGENTS.md) for the selected target and persistent user
authorization. Historical `gw0911g` repairs are not current steps.

`gateway-maintenance.ps1 -Mode Plan` calls the retained canonical
read-only verifier directly, with the actual preserved component evidence. It
does not call the bootstrap dispatcher, edit stage status, select another CLI
account, or fake fresh-install state. A historical failed final verification
requires explicit acknowledgement and is recorded as Failed beside the new
independent verification. Its cause is not reclassified from a stale message.
Current verification failures stop Plan; cached success does not authorize it.
The fixed verifier runs in an isolated PowerShell process with a 15-minute total
deadline. Timeout stops that exact child process tree and accepts no result.
Only one bounded, typed result line is read; other stdout/stderr is suppressed.

This initial baseline supports a conventional, completed Core deployment with
either Completed or Failed final verification. Other unfinished stages, recovery
variants, or already-installed optional capabilities fail explicitly. Each Plan
has a new timestamp and creates a separate file under
`.maintenance\upgrades\<releaseId>\<plan SHA-256>\plan.json`. Never commit this
environment-specific evidence. Files are create-only, not overwritten.
The generated local `.maintenance\.gitignore` excludes all evidence; an existing
different exclusion file is rejected, not overwritten. Evidence paths under
`.bootstrap` are forbidden.

## Request

Supply a JSON file outside the source/build inventory, for example under
`.maintenance\requests`. Replace all placeholders; fingerprints are lowercase
`sha256:` plus 64 hex digits. IDs must be canonical lowercase GUIDs.

```json
{
  "schemaVersion": 1,
  "releaseId": "protection-v1",
  "target": {
    "subscriptionId": "<subscription GUID>",
    "tenantId": "<tenant GUID>",
    "deploymentOwnershipId": "<original ownership GUID>",
    "resourceGroupName": "rg-<project>-dev",
    "location": "koreacentral",
    "projectName": "<project>",
    "environment": "dev"
  },
  "acknowledgeHistoricalVerificationFailure": true,
  "capabilities": {
    "promptShields": { "enabled": true, "sku": "S0", "acceptPaidUsage": true },
    "purview": { "enabled": true, "executorSku": "B1", "acceptPaidHosting": true }
  },
  "images": {
    "api": "",
    "worker": "",
    "adminUi": "",
    "databaseMigrator": ""
  },
  "database": {
    "name": "GatewayDb",
    "currentSchemaFingerprint": "<original verified schema fingerprint>",
    "targetSchemaFingerprint": "<independently established target fingerprint>",
    "rollbackStrategy": "RetainExpandedSchema",
    "scripts": [
      {
        "path": "infrastructure\\sql\\YYYYMMDD_reviewed_additive_change.sql",
        "sha256": "<exact SQL bytes fingerprint>",
        "classification": "Additive"
      }
    ]
  }
}
```

Empty image values mean artifacts are not yet bound, never an instruction to use
`latest`. Nonempty values require the component's exact existing ACR repository
and immutable digest. The SQL array is unique and ordinally ordered. An unchanged
schema requires an empty array; a changed fingerprint requires scripts.
The retained Plan expects each requested SQL file to occur in the candidate migrator's exact literal
`GetPrepareScriptNames` allowlist. The Plan binds that source file's checksum and
ordered list as well as the SQL bytes; a new unreferenced SQL file is rejected.
The absent migrator's manifest and order must be re-established before this
contract can be validated end to end.
`Additive` is a **review assertion**, not a SQL semantic safety proof. The Plan
does not execute SQL or infer compatible-reader or deployed artifact proof.
The v2 packaging and private migration implementations referenced below are not
invoked by this v1 CLI and do not lift its review-only hold.

```powershell
.\operations\gateway-maintenance.ps1 -Mode Plan `
  -StatePath '<preserved target state JSON>' `
  -ConfigPath '<preserved original config JSON>' `
  -SourceRoot '<reviewed candidate source directory>' `
  -RequestPath '.maintenance\requests\protection-v1.json'

.\operations\gateway-maintenance.ps1 -Mode ValidatePlan `
  -StatePath '<same original state JSON>' `
  -ConfigPath '<same original config JSON>' `
  -SourceRoot '<same candidate source directory>' `
  -PlanPath '<returned plan path>' `
  -ExpectedPlanFingerprint '<independently selected exact plan fingerprint>'
```

`ValidatePlan` checks local integrity, current source/verifier/SQL hashes, original
file hashes, deterministic exact resource/role scope and required review fields.
It **does not refresh live verification** or attest approval. A hash is an
integrity binding, not an authorization signature. Execution requires the separate
v2 workflow's candidate, fresh Plan and exact approval bindings. The v1 modes
`Execute`, `Verify` (post-upgrade acceptance), and `Rollback` validate local
bindings and then throw `UpgradeNotImplemented`. They are intentionally not
implemented execution routes and never record a successful stage or contact a
mutation API. Do not use a v1 Plan in place of a reviewed v2 Plan.

## Database upgrade protocol

The generated `databaseUpgradeProtocol` is a deterministic contract descriptor,
not an executed migration receipt. It keeps the original deployment ownership,
accepted source and `A365GatewayBootstrapInitializationIntent` separate from the
candidate upgrade source, before/after schema fingerprints and executed SQL
checksums. The original marker must remain byte-for-byte unchanged.

The separate create-only private Blob maintenance receipt binds the exact approved Plan,
previous upgrade receipt (null for the first upgrade), one-shot execution intent,
private job/execution identity, migrator digest, before/after original-marker
fingerprints, exact schema/principal readback and registration-preservation
evidence. An unknown outcome permits only bounded, exact read-only reconciliation,
not automatic SQL/job replay.

Runtime DB attestation binds the original ownership/source/marker
to the verified new upgrade receipt, upgrade Plan/source and current schema and
database principals. The canonical nonsecret receipt JSON and fingerprint are
supplied through `DatabaseAttestation.Upgrade`; the existing probe checks them in
addition to the original marker, current schema and principals. Its cache is
scoped to the complete configuration binding. No additional SQL extended
properties or bootstrap-marker changes are made: these would themselves change
the existing schema fingerprint. These fields do not grant SQL authority or
replace bootstrap proof. Connectivity readiness is not upgrade attestation. Rollback retains the
expanded schema and user writes, using only independently compatible old code.

The retained SQL directory includes configuration-intent, runtime-test,
capability-preparation-history and prompt-protection-context schema changes.
Their existence does not prove they occur in a runnable migration manifest. The
missing migration tool's ordering, exact script checksums, EF-model comparison,
preservation transaction and receipt reconciliation must be restored and tested
against those retained files.

The orchestration expects separate `upgrade`, `upgrade-verify` and
`upgrade-schema-plan` contracts. Upgrade binds an exact manifest, original
ownership/source, execution intent, Plan fingerprint, private DNS and job managed
identity. Verification reconciles an existing receipt without starting SQL.
Schema planning obtains the compiled target-model fingerprint without opening
SQL. These are required integration contracts, not evidence that the absent
runner currently implements or passes them.

The target-model fingerprint and actual physical post-migration fingerprint have
different roles: an additive migration can produce a different physical column
order from a fresh EF creation. The candidate must verify schema equivalence and
record actual readback without weakening exact comparison or editing original
initialization evidence. Frozen-candidate validation belongs to M5 in
[MILESTONES.md](../MILESTONES.md).

## Packaging and adapter slices

`GatewayUpgradePackaging.psm1` provides `New-GatewayUpgradeCandidate` and
`Test-GatewayUpgradeCandidate`. It uses a retained clean packaging baseline only
for disclosed missing build prerequisites (`Directory.Build.props`, `global.json`,
`nuget.config`, `VERSION`); it never restores the main working tree. Other deleted
source files stay deleted. The generated exact-file `.dockerignore` starts by
excluding everything and permits only the manifested files. Local/application
configuration, state, secrets, generated outputs, Python and virtual environments
are excluded. Provenance records exact hashes, origins, modifications and excluded
deletions. Published runtime package binaries require a separate explicit asset
binding; they are not admitted as arbitrary `bin`/`obj` contents.

`GatewayUpgradeExecution.psm1` contains guarded adapters for create-only action
evidence, the documented ARM container-lease API, ACR image builds, exact-scope
What-If/deployment, Content Safety S0 and a dedicated private SQL upgrade job.
Dedicated maintenance Bicep templates cover Content Safety, the SQL job,
protection queue, Windows executor, package publisher and source-only executor
updates. The v2 pipeline uses
the shared capability-preparation receipt/history transition instead of rewriting
original bootstrap facts. Missing migration and verification tooling must be
restored before claiming this complete path is runnable. Compile/test
success and local implementation are not claims of deployed policy readiness,
licensing, authenticated provider execution or full product acceptance.

## Historical v1 scope and shared cost boundary

The v1 proposed allowlist includes the deployment-owned Content Safety account, its
API-managed-identity Cognitive Services User assignment, a **new** versioned
private SQL upgrade job, and Modify-only existing worker/API/Admin resources.
It does not grant arbitrary template, command, script, callback, role, principal,
subscription or resource-group inputs. This v1 proposal is not the complete v2
deployment allowlist. The implemented v2 path separately derives and binds the
Purview identity/certificate/executor and private SQL job scopes; review those
exact scopes in its fresh Plan. Content Safety provisioning must first prove
the proposed account name absent.

Pricing and capacity must be evaluated for the exact target, region, SKU and
planned usage during release planning. Networking, storage, builds, logging and
Microsoft 365/Purview licensing or usage are separate inputs. A paid-usage
acknowledgement is not a spending cap or approval for unrelated resources.

## Acceptance and continuation

Restoring missing tools and tests belongs to M1; candidate validation and release
preparation belong to M5; live provider and preserved-registration acceptance
belong to M6 in [MILESTONES.md](../MILESTONES.md). This guide is an operational
contract, not another completion checklist. The detailed v2 lifecycle is in
[gateway-upgrade.md](gateway-upgrade.md).

Rollback means compatible code on the expanded schema, not destructive SQL,
restoring over user writes, purging queues or repeating Registry creation.
Single-revision HTTP readiness does not by itself promise zero downtime.
