# Operating an existing Gateway

This directory contains reviewed scripts and runbooks for a Gateway that already
has a deployed foundation. It is not the fresh-subscription entry point. For a new
deployment, use `./gateway setup` and the [bootstrap guide](../bootstrap/README.md).

Start every existing-environment action from current source, read the live
[deployment checkpoint](../docs/operations/development-deployment-status.md), and
run the smallest read-only preflight or verification that proves the intended
target. A successful local command is not evidence that Azure changed.

## Routine commands

Run these from the repository root:

| Command | Purpose |
|---|---|
| `./gateway status` | Read local bootstrap checkpoint/readiness state without Azure calls. |
| `./gateway verify` | Rerun the canonical read-only deployment verifier. |
| `./gateway diagnose` | Create a sanitized local diagnostic bundle. |
| `./gateway open` | Open the recorded verified Admin UI. |
| `./gateway resume` | Reconcile and continue an interrupted accepted bootstrap. |

Do not delete or edit `.bootstrap/` to force progress. It is the reconciliation
authority for a bootstrapped environment.

## Reviewed scripts

| Script | Use |
|---|---|
| `test-provisioning-prerequisites.ps1` | Run fail-closed, read-only Agent ID and provisioning preflight checks. |
| `verify-first-registration.ps1` | Verify one explicitly selected Active registration and temporary-key lifecycle. |
| `upgrade-bootstrap-admin-ui.ps1` | Promote only the Admin UI in an eligible completed bootstrap deployment; invoke through `./gateway upgrade-admin-ui`. |
| `FirstRegistrationVerificationState.psm1` | Durable safe state contract for the first-registration verifier. |

Database migration and workflow-Entra helpers under `tools/` are internal inputs to
the canonical deployment/recovery paths, not alternate installers.

## Runbooks

| Task | Runbook |
|---|---|
| Entra apps, roles, and federation | [Entra setup](../docs/operations/entra-setup-runbook.md) |
| Agent 365 activity/OTel | [Observability setup](../docs/operations/agent365-observability-setup.md) |
| Purview policies and runtime | [Purview setup](../docs/operations/purview-setup-runbook.md) |
| Backup and restore | [Backup and recovery](../docs/operations/backup-recovery.md) |
| Credential and certificate rotation | [Credential rotation](../docs/operations/credential-rotation.md) |
| Version promotion | [Upgrade strategy](../docs/operations/upgrade-strategy.md) |
| Security event | [Incident response](../docs/operations/incident-response.md) |

Purview operations must preserve the Microsoft location split: the Know Your Data
collection uses the fixed tenant-wide enterprise-AI-apps location as
`LocationType=Group`; blueprint-specific DLP uses the reusable blueprint
application/client ID as `LocationType=Individual`. Both are Application-plane
locations.

## Recovery rules

- Diagnose and reconcile before mutating.
- Preserve failed jobs, queue/dead-letter state, outbox rows, image digests, and
  correlation evidence until the applicable runbook authorizes a disposition.
- Never repeat an external create call after an unknown outcome unless the contract
  defines an exact read-only reconciliation path.
- Never print secret runtime input, access tokens, authorization headers, clear
  Gateway keys, prompts, responses, or dependency bodies.
- Use bootstrap's bounded recovery commands only when its state reports the exact
  eligible condition.
- Treat a deleted completed resource group as disaster recovery; do not replay the
  preserved bootstrap state into missing resource-group credentials.

Declarative assets used by these scripts are documented in the
[infrastructure index](../infrastructure/README.md).
