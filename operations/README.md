# Gateway operations

Routine administration for an installed Gateway.

- Product / platforms: [product brief](../docs/spec/product-brief.md)
- UI: [UI design](../docs/console/design.md)
- Runtime: [system architecture](../docs/architecture/system-architecture.md)
- Fresh install: [bootstrap](../bootstrap/README.md)

Commands use an explicitly selected configuration and its preserved deployment
state. Prefer the **zero-Microsoft-infra** profile (Compose/Kubernetes +
PostgreSQL + RabbitMQ + Vault/OpenBao + S3). Essential product services remain
Entra / Graph / Agent 365 / Purview / Prompt Shields. Legacy Azure infrastructure
operations remain only for installations that still use that transitional profile.

## Launcher commands

| Command | Boundary |
|---|---|
| `gateway status` | Read local deployment state |
| `gateway verify` | Read back current bindings for the selected profile |
| `gateway open` | Open the recorded verified hosted UI endpoint |
| `gateway diagnose` | Create a bounded, sanitized diagnostic bundle |
| `gateway resume` | Reconcile eligible interrupted work for the same accepted plan |
| `gateway upgrade-admin-ui` | Transitional Admin UI-only promotion (legacy Azure profile) |
| `gateway recover-database` | Reconcile an eligible interrupted database operation |
| `gateway repair-database` | Run the exact reviewed database repair contract |

On Windows use `.\gateway.cmd`; on macOS/Linux use `./gateway`.
Run `gateway --help` for arguments. Never edit a checkpoint to force progress,
reuse a deleted target, or replay a create whose provider outcome is unknown.

## Supported implementation files

- [Provisioning preflight](verify-provisioning-prerequisites.ps1) — read-only
  prerequisite checker used by the canonical verifier
- [Admin UI promotion](upgrade-bootstrap-admin-ui.ps1) — transitional hosted-UI
  promotion for the legacy profile; Console cutover replaces this path
- [Windows package builder](build-purview-executor-package.ps1) — Purview executor
  packaging when that optional capability is enabled
- [Upgrade orchestration](gateway-upgrade.ps1) / [upgrade contract](gateway-upgrade.md) —
  **legacy Azure-profile** source-bound maintenance; portable-profile maintenance
  uses image digest + PostgreSQL migrator contracts without Azure What-If

## Purview automation reference prerequisite

Before the first Purview tenant connection, ensure the Security & Compliance
service-principal reference exists for the installed automation application.
This is a Microsoft 365 provider prerequisite, independent of whether the Gateway
runs on AWS, GCP, Azure, or on-prem. Follow the exact AppId / ObjectId checks
required by the installed deployment; do not rewrite bootstrap receipts when
repairing an external prerequisite.

## Portable vs legacy maintenance

| Concern | Portable target | Legacy Azure profile |
|---|---|---|
| Plan dry-run | Compose/Kubernetes manifests | Bicep What-If |
| Database | PostgreSQL migrator | Azure SQL migrator path |
| Queues | RabbitMQ | Service Bus |
| Secrets | Vault/OpenBao | Key Vault |
| Images | Any OCI registry digests | ACR digests |

Product logic (outbox, workflow versions, exact-ID recovery) is identical across
profiles.
