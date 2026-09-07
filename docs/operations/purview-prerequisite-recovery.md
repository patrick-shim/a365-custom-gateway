# Recover a failed Purview prerequisite stage

Apply the [end-to-end execution contract](../agent-guides/end-to-end-execution.md)
within this runbook's exact authority and verification boundary; a subtask result
does not complete product delivery or override an explicit hold.

This narrow recovery applies only to thirteen completed bootstrap stages followed
by a failed **Purview capability prerequisites** stage without completion evidence.
It requires the original local configuration, state, accepted snapshot, and exact
operator authority. It cannot be combined with database recovery, manual database
repair, or a pre-inert source correction. It does not recover a deleted deployment.

Read the [deployment checkpoint](development-deployment-status.md) first. The
recovery implementation and offline evidence do not prove a live recovery passed.

## Review and execute

From the canonical repository checkout, with the intended Azure session selected:

```powershell
pwsh -NoProfile -File bootstrap/recover-purview-prerequisites.ps1 `
  -Mode Plan -RecoveryMode AbsentCertificate
```

Plan performs provider reads and writes only local review artifacts. It verifies
the existing owned application and principal, original administrator, exact role
assignments, and certificate metadata. Both the Entra certificate and the exact
Key Vault certificate secret must be absent. An existing or partial certificate
requires separate read-only reconciliation; this recovery never replaces it.

After reviewing that plan and obtaining its exact mutation approval, execute the
same mode with its returned fingerprint:

```powershell
pwsh -NoProfile -File bootstrap/recover-purview-prerequisites.ps1 `
  -Mode Execute -RecoveryMode AbsentCertificate `
  -ExpectedPlanFingerprint '<reviewed AbsentCertificate sha256 fingerprint>' -Yes
```

When the failed stage already has exact, complete readback for both grants and
the certificate in both stores, use the separately reviewed reconciliation mode:

```powershell
pwsh -NoProfile -File bootstrap/recover-purview-prerequisites.ps1 `
  -Mode Plan -RecoveryMode CompletePrerequisiteReconciliation
```

This mode is read-only and pins the corrected tooling snapshot while preserving
the original accepted plan, completed stages, images, and SQL binding. Execute
with its exact plan fingerprint only after review. It never creates, rotates,
replays, or repairs a prerequisite; normal Resume later performs only the
stage's `ReconcileOnly` verification. Partial, absent, changed, or mismatched
provider state is rejected.

Review the returned plan fingerprint and ignored local plan. The plan pins the
original accepted authorization, owner, configuration, completed prefix, failed
record, existing identity object IDs, role tuple, certificate resource, planned key
ID, template hash, and a corrected immutable tooling snapshot. Runtime source,
infrastructure, templates, workload images, and SQL inputs must remain unchanged.

For `CompletePrerequisiteReconciliation`, use that mode's exact returned
fingerprint after review:

```powershell
pwsh -NoProfile -File bootstrap/recover-purview-prerequisites.ps1 `
  -Mode Execute -RecoveryMode CompletePrerequisiteReconciliation `
  -ExpectedPlanFingerprint '<reviewed sha256 fingerprint>' -Yes
```

Both commands hold the bootstrap state lock and recheck their own plan before
local receipt writes. Reconciliation remains provider-read-only. Only
`AbsentCertificate` may complete these three fixed prerequisites:

1. the existing automation principal's exact `Exchange.ManageAsApp` assignment;
2. its exact tenant-root Compliance Administrator assignment; and
3. one certificate with the precommitted key ID, stored privately in the exact
   Key Vault location and published to the pinned application as a public key.

An assignment already present in Plan stays readback-only, including after a
restart. Each missing operation persists `Started` before its single mutation.
A lost response permits exact readback only; an absent later read never permits
another attempt. A partial certificate remains unresolved. Preserve the plan and
provider objects; do not clear operation records, repeat the whole identity Ensure
function, rotate credentials, or edit the original accepted snapshot.

## Resume and verify

Recovery completion independently reads the entire automation capability and
persists a separate completion receipt. It leaves the failed bootstrap stage
unchanged. Run the ordinary visible Setup Resume review or the public Resume
command. Only its normal read-only reconciler may complete the failed stage.

Resume revalidates the recovery receipt and restores the exact corrected tooling
snapshot before each callback while retaining the original deployment source.
Completed side-effect stages three through thirteen are validation-only. A failed
readback preserves their records. The first two local/session checks may retry
after an interruption; the Azure identity must still match the original binding.

Finish all nineteen stages and run `gateway verify`. This proves deployment
readback only. Registration, delegated Registry completion, Agent 365 landing,
Prompt Shields, Windows Purview execution, and DLP readiness need their own live
evidence. See [Purview setup and readiness](purview-setup-runbook.md).

## Supported provider contracts

The recovery uses the existing Graph v1.0 mechanisms for
[application-role assignments](https://learn.microsoft.com/graph/api/serviceprincipal-post-approleassignments?view=graph-rest-1.0),
[directory-role assignments](https://learn.microsoft.com/graph/api/rbacapplication-post-roleassignments?view=graph-rest-1.0),
and [public application certificate updates](https://learn.microsoft.com/graph/api/application-update?view=graph-rest-1.0).
Directory-role reads use the documented `$filter` and `$select` query options;
single-quoted PowerShell strings must not contain literal escaping backticks in
those option names. Provider success responses are followed by independent exact
readback and are never sufficient on their own.

## Applicability to stopped attempts

The complete-prerequisite reconciliation case is thirteen completed stages and a
failure at Purview domain readback, with both grants and the certificate complete
in their respective stores and accepted source predating corrected tooling.
Partial certificate publication is not that case; both modes reject it.
Neither mode applies to a later Gateway runtime deployment failure or a deleted
target. Consult the [current continuation checkpoint](../agent-continuation.md)
and deployment checkpoint for the actual stopped stage and exact authority before
any live action.
