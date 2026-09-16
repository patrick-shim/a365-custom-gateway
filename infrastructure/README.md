# Infrastructure assets

This directory contains the declarative Azure and SQL assets consumed by the
[bootstrap lifecycle](../bootstrap/README.md) and
[existing-environment operations](../operations/README.md). Templates and SQL
files are inputs to those workflows, not independent installation instructions.

The related Azure resources and supporting tools were deliberately removed.
Retained assets do not prove a current deployment. The complete installation
command is **not yet revalidated runnable**: `tools/Gateway.Setup`,
`tools/Gateway.DatabaseMigrator`, `tools/Gateway.LiveVerification` and the former
`tests/` projects are absent. [MILESTONES.md](../MILESTONES.md) is the sole
completion and acceptance record.

## Layout

| Path | Purpose |
|---|---|
| `bicep/main.bicep` | Workload composition for an existing foundation. |
| `bicep/admin-ui.bicep` | Bounded Admin UI deployment. |
| `bicep/modules/` | Shared Azure resource modules. |
| `bicep/parameters/` | Environment parameter inputs. |
| `bicep/maintenance-*.bicep` | Bounded inputs to the maintenance lifecycle. |
| `sql/` | Forward schema changes whose order and checksums must be bound by the migration workflow. |

Bootstrap-specific subscription, foundation, private-endpoint and database-job
composition lives under `bootstrap/infra/`.

## Azure boundary

The retained templates describe Container Apps, Container Registry, SQL, Service
Bus, Blob storage, Key Vault, networking, managed identities, role assignments,
Application Insights and protection dependencies. Purview execution also uses a
Windows App Service and its runtime/package infrastructure.

New bootstrap configurations require the shared Azure AI Content Safety resource
for Prompt Shields; per-agent use remains optional. The templates disable local
authentication and assign the Gateway API managed identity the required
data-plane role, without provisioning an account key. Accepted older
configurations may retain their earlier capability choices.

Purview policy objects belong to Microsoft 365 and are not created by Azure
Bicep. The authorized Security & Compliance PowerShell integration manages a
fixed tenant-wide `Group` location for Know Your Data and a blueprint-specific
`Individual` location for DLP. Azure assets supply the integration's runtime
dependencies; successful infrastructure deployment does not prove policy
configuration or effective protection.

## SQL boundary

The retained orchestration expects `tools/Gateway.DatabaseMigrator` to apply
source-bound schema changes and verify the database. That tool's source is absent,
so its complete manifest, ordering and execution must be restored and checked
against the retained schema before claiming a runnable migration path.

Empty-database initialization is intended only when SQL reports zero user tables.
Existing environments require the maintenance lifecycle and exact database
readback. Do not apply individual SQL files manually or infer completion from
their filenames. Preserve the original initialization evidence and user data;
rollback uses compatible code on the expanded schema.

## Validation boundary

Source restoration and baseline validation belong to M1; release preparation and
live acceptance belong to M5 and M6 in [MILESTONES.md](../MILESTONES.md). Validation
must include template compilation, configuration contracts, migration ordering,
real schema and preservation checks, and the relevant restored test projects.
The absent test projects have not been replaced by generated binaries.

An authorized live deployment requires a current target-bound plan and What-If.
Local compilation or test results do not prove Azure, tenant or database state.
