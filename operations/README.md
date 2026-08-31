# Operational scripts

This directory contains reviewed scripts for an existing Gateway environment. It is
not the day-zero installation entry point; use `../gateway setup` (or
`../gateway.cmd setup` on Windows) and
[`../bootstrap/README.md`](../bootstrap/README.md) for a fresh subscription or a
deleted resource group.

The evidence and authorization checklist for the first disposable live proof is
[`../docs/operations/clean-subscription-bootstrap-proof.md`](../docs/operations/clean-subscription-bootstrap-proof.md).

| Script | Purpose |
|---|---|
| `deploy.ps1` | Deploy current workload Bicep to an existing foundation. |
| `upgrade-bootstrap-admin-ui.ps1` | Promote only `gateway-admin` in the exact same completed/verified bootstrap resource group; invoked through `../gateway upgrade-admin-ui`, not as a bootstrap mode. |
| `repair-bootstrap-api-attestation.ps1` | Resume the exact reviewed API-attestation correction for an eligible failed clean bootstrap; builds and updates only `gateway-api`, then runs canonical final verification. |
| `test-provisioning-prerequisites.ps1` | Run fail-closed, read-only provisioning preflight checks. |
| `invoke-development-canary.ps1` | Historical evidence helper only; there is no current canary release gate and it must not be replayed. |
| `setup-sql-user.ps1` | Configure reviewed SQL workload principals. |
| `bootstrap-provisioning-worker.ps1` | Narrow legacy worker bootstrap/recovery helper; not the repository bootstrap entry point. |

The scripts consume templates from [`../infrastructure/`](../infrastructure/README.md)
and must follow the current checkpoint in
[`../docs/operations/development-deployment-status.md`](../docs/operations/development-deployment-status.md).
Run read-only preflight or Bicep what-if before any authorized mutation. Never infer
live readiness from a successful local invocation, and never print or persist secret
runtime input.

For an Admin UI source-only promotion after the original bootstrap is complete and
currently verified, run from the repository root:

```bash
./gateway upgrade-admin-ui --config bootstrap/config.json --yes
```

This path retains the original bootstrap provenance, writes a separate ignored
upgrade receipt, builds only `gateway-admin`, disables private-endpoint
redeployment, and rejects What-If Create/Delete or resources outside the exact
Admin UI allowlist. It verifies the immutable UI digest and Entra/managed-identity
boundary, and proves the API, workflow-v3 worker, Service Bus queue counts, and
accepted bootstrap plan did not change. Its receipt identifies the prior UI digest;
rollback is not automatic and requires separate review.

For the exact failed clean-bootstrap boundary whose completed manual database repair
is healthy but whose original API image cannot satisfy the v1 database-attestation
contract, run from the repository root:

```bash
./gateway repair-api-attestation --config bootstrap/config.json --yes
```

This correction has no Plan, What-If, dry-run, Bicep, or resource-replay path. It
synthesizes build source from the preserved original accepted snapshot, overlays
only the two literal-hash-pinned attestation files, builds only `gateway-api`, and
updates only the existing API Container App to the resulting immutable digest. A
resumable receipt is written under
`.bootstrap/evidence/<resource-group>/api-attestation-correction/` before build and
deployment mutations. Completion requires the exact ACR run and tag digest, one
healthy receipt-bound API revision, unchanged API configuration/identity and full
worker/queue boundaries, the exact v1 `Attested` endpoint, and the canonical final
bootstrap verifier. It never replays an earlier bootstrap step.
