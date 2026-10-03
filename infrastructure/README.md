# Infrastructure assets

Declarative and schema assets for the product in the
[product brief](../docs/spec/product-brief.md). Consumed by
[bootstrap](../bootstrap/README.md) and [operations](../operations/README.md).

## Product direction

**Infrastructure target: zero Microsoft dependence.** PostgreSQL, RabbitMQ,
OpenBao/Vault, S3-compatible storage, Docker Compose and/or Kubernetes, any OCI
registry. Take the same images to **AWS (ECS/EKS), GCP, or on-prem** and they
must run without Azure SQL, Service Bus, Key Vault, Container Apps, ACR, or Blob.

**Product services stay Microsoft and essential:** Entra, Graph, Agent 365,
Purview, Prompt Shields. Those are APIs — not the running environment.

Architecture: [system architecture](../docs/architecture/system-architecture.md).
**Logic stays the same** (outbox, queue names, migrator, C# API/worker).

## Profiles

| Profile | Status | Assets |
|---|---|---|
| **Portable** (Compose / Kubernetes) | **Product target** | To be the canonical install path — PostgreSQL, RabbitMQ, Vault/OpenBao, MinIO/S3, OCI images |
| **Legacy Azure PaaS** | Transitional | Existing `bicep/` and `bootstrap/infra/` templates |

Do not treat Bicep success as the long-term product shape.

## Layout (repository today)

| Path | Purpose |
|---|---|
| `bicep/main.bicep` | Legacy Azure workload composition |
| `bicep/admin-ui.bicep` | Legacy Admin UI Container App |
| `bicep/modules/` | Legacy Azure resource modules |
| `bicep/parameters/` | Legacy environment parameters |
| `bicep/maintenance-*.bicep` | Legacy maintenance inputs |
| `sql/` | Forward schema scripts bound by the migrator (engine-portable intent: PostgreSQL target) |
| *(planned)* `compose/`, `kubernetes/` | Portable profile manifests |

Bootstrap-specific Azure foundation templates live under `bootstrap/infra/` and
are legacy-profile inputs.

## Portable boundary (target)

| Concern | Target |
|---|---|
| Database | PostgreSQL (+ SQLite for local/dev only) |
| Queues | RabbitMQ; logical names `gateway-provisioning-v3`, `gateway-protection-admin-v1` |
| Secrets | OpenBao or HashiCorp Vault |
| Content | S3-compatible bucket |
| Apps | Containers for API, worker, Console; optional Windows executor where Purview is enabled |
| Images | Digest-pinned OCI artifacts from any registry |

Purview policy objects still belong to Microsoft 365 and are not created by
infra templates. Successful infra deploy never proves policy enforcement.

## Legacy Azure boundary (transitional)

Existing templates may still describe Container Apps, ACR, Azure SQL, Service
Bus, Blob, Key Vault, managed identities, Application Insights, and Windows App
Service for the Purview executor. Read those as the **legacy profile** only.
New documentation and new work prefer the portable profile.

## Database / migrator boundary

`tools/Gateway.DatabaseMigrator` applies source-bound schema changes and verifies
the database. Target engine is **PostgreSQL**. Do not apply individual SQL files
manually or infer completion from filenames. Preserve data across upgrades;
rollback uses compatible code on the expanded schema.

## Validation boundary

Validation includes template/manifest compilation, configuration contracts,
migration ordering, and real schema/preservation checks for the **selected
profile**. Local compilation does not prove live cloud or on-prem state.
