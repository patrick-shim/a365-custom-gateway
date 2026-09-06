# Recover a failed Purview prerequisite stage

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
pwsh -NoProfile -File bootstrap/recover-purview-prerequisites.ps1 -Mode Plan
```

Plan performs provider reads and writes only local review artifacts. It verifies
the existing owned application and principal, original administrator, exact role
assignments, and certificate metadata. Both the Entra certificate and the exact
Key Vault certificate secret must be absent. An existing or partial certificate
requires separate read-only reconciliation; this recovery never replaces it.

Review the returned plan fingerprint and ignored local plan. The plan pins the
original accepted authorization, owner, configuration, completed prefix, failed
record, existing identity object IDs, role tuple, certificate resource, planned key
ID, template hash, and a corrected immutable tooling snapshot. Runtime source,
infrastructure, templates, workload images, and SQL inputs must remain unchanged.

Use the exact returned fingerprint after that review:

```powershell
pwsh -NoProfile -File bootstrap/recover-purview-prerequisites.ps1 `
  -Mode Execute -ExpectedPlanFingerprint '<reviewed sha256 fingerprint>' -Yes
```

The command holds the bootstrap state lock and rechecks the plan before writes.
It may complete only three fixed prerequisites:

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

## Current stopped attempt

The current operator stopped live work for a model handoff. Both role grants passed
exact readback. Certificate storage succeeded, but Entra rejected its public-key
update and still has zero keys. The operation is preserved as Started. This command
deliberately refuses that partial state. Do not repeat Execute expecting it to repair
the certificate; diagnose the exact failure and design a separately reviewed repair
that preserves the existing certificate and operation evidence. See the current
continuation checkpoint before any live action.
