# Operating a Gateway

This directory retains scripts and lifecycle contracts for an existing Gateway.
The user deliberately removed the related Azure resources; there is no current
deployment asserted by these documents. For a new installation, start with the
[bootstrap guide](../bootstrap/README.md).

The full installation and maintenance paths are **not yet revalidated against a
fresh or preserved Azure environment**. The minimum Setup, DatabaseMigrator and
LiveVerification sources and local test fixtures are restored. Retained scripts
and old output directories do not establish a current deployment or release.

[MILESTONES.md](../MILESTONES.md) is the sole completion and acceptance record.
Follow [AGENTS.md](../AGENTS.md) for authorization, the selected Azure target,
credential handling and browser preferences. Existing explicit authorization
persists within its scope. Historical prose is not a reason to request it again.

## Retained command surface

These commands describe the intended lifecycle once its prerequisites and target
state are verified; they are not instructions to recreate deleted resources now.

| Command | Purpose and effects |
|---|---|
| `./gateway status` | Read local bootstrap checkpoint state. |
| `./gateway verify` | Run the live, read-only deployment verifier. |
| `./gateway diagnose` | Create a sanitized local diagnostic bundle. |
| `./gateway open` | Open the Admin UI recorded in verified state. |
| `./gateway resume` | Reconcile and continue an eligible interrupted bootstrap; may mutate the target. |

Use `gateway.cmd` for the Windows launcher. A preserved `.bootstrap/` checkpoint
is operational reconciliation data, not project acceptance. Do not edit it to
force progress or replay completed state against deliberately deleted resources.

## Retained scripts and guides

| Script or guide | Scope |
|---|---|
| [Provisioning preflight](test-provisioning-prerequisites.ps1) | Read-only Agent ID and provisioning checks against the selected live target. |
| [First registration verifier](verify-first-registration.ps1) | Verify an explicitly selected Active registration; its temporary-key lifecycle includes mutations. |
| [Admin UI promotion](upgrade-bootstrap-admin-ui.ps1) | Promote the Admin UI in an eligible completed deployment through `gateway upgrade-admin-ui`. |
| [First-registration state contract](FirstRegistrationVerificationState.psm1) | Preserve verification and temporary-key reconciliation state. |
| [Versioned upgrade](gateway-upgrade.md) | Candidate, plan, promotion, verification, rollback and bounded abort contracts. |
| [Maintenance v1 contract](gateway-maintenance.md) | Historical baseline/plan scaffold; not an alternate execution path. |

Some `operations/test-*` scripts call real providers or exercise mutable workflows.
Review their source and target requirements before running them; their names do
not imply offline tests. The old `gw0911g` hotfix and repair scripts are retained
incident-specific source, **not current setup, upgrade or recovery steps**.

The [local baseline runner](../tools/Test-LocalBaseline.ps1) explicitly includes
only the portable packaging, abort-journal and Purview-metadata scripts below,
each in a separate PowerShell process. It does not discover all operator scripts.

| Retained test script | Boundary and prerequisites |
|---|---|
| [Packaging boundary](test-gateway-upgrade-packaging.ps1) | Local source fixture files; no provider or package build. |
| [Abort lifecycle](test-gateway-upgrade-abort.ps1) | Synthetic local journal/authority fixtures; no provider or lease calls. |
| [Purview policy metadata](test-purview-policy-metadata.ps1) | Loads only validator functions from the parsed authored script; no provider calls. |
| [Source-only maintenance](test-gateway-upgrade-source-only.ps1) | Reads preserved bootstrap/configuration inputs; excluded from the clean M1 suite because it requires historical environment artifacts. |
| [Startup diagnostic package](test-gw0911g-startup-diagnostic-package.ps1) | Inspects previously published package bytes; excluded from M1 source-only verification. |

All retained hotfix/repair wrappers, executor-capacity repair and Admin UI promotion
have provider-mutating modes. A locally displayed Plan or an offline test of a
validator does not make their Apply/Execute modes safe to run as unit tests.

## Protection operations

See the [protection design](../docs/architecture/protection-settings-plan.md) and
[Windows executor architecture](../docs/architecture/purview-windows-executor.md)
for the retained contracts. Provisioned capability, saved configuration and
runtime-proven protection are separate states.

Know Your Data uses the fixed tenant-wide enterprise-AI-apps location as
`LocationType=Group`; blueprint-specific DLP uses the reusable blueprint
application/client ID as `LocationType=Individual`. Both use the Application plane.

Collection enablement is separate from DLP simulation.
`New-FeatureConfiguration` and `Set-FeatureConfiguration` support native
`Enable`/`Disable`. The Gateway's legacy `AuditOnly` and `Enforce` collection
choices both map to an enabled collection policy. Do not send DLP
`TestWithoutNotifications` or `TestWithNotifications` as collection-policy modes.

For a collection scoped to a specific sensitive information type,
`IsIngestionEnabled=false` preserves that scope. The flag controls full AI content
capture, not collection enablement. Full content capture requires the All
classifier scope; a saved choice must not be silently widened.

## Recovery principles

- Diagnose and reconcile exact target state before a mutation.
- Preserve failed jobs, queue/dead-letter state, outbox rows, artifact digests and
  correlation evidence until the chosen recovery contract determines disposition.
- Reconcile an unknown external create outcome before considering any repeat.
- Keep credentials, access tokens, authorization headers, clear Gateway keys and
  sensitive request bodies out of logs and diagnostics.
- Use a bounded recovery command only when state proves its eligible condition.
- Treat deliberately deleted resources as a fresh planning boundary, not an
  invitation to replay old deployment or incident state.

The [infrastructure index](../infrastructure/README.md) describes the declarative
inputs. The [API contract](../docs/api/api-contract.md) describes caller behavior.
