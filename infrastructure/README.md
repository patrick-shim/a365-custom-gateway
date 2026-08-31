# Infrastructure assets

This directory contains the declarative Azure and SQL assets used by bootstrap and
reviewed existing-environment operations. It is not an orchestration entry point and
contains no credentials.

Use [bootstrap](../bootstrap/README.md) for a fresh subscription and
[operations](../operations/README.md) for an existing deployment. Do not run an
individual template or migration as a substitute for those workflows.

## Layout

```text
infrastructure/
├── bicep/
│   ├── main.bicep                 existing-foundation workload composition
│   ├── admin-ui.bicep             bounded Admin UI deployment
│   ├── modules/                    reusable Azure resource modules
│   └── parameters/                 environment parameter files
└── sql/                            ordered forward-only schema changes
```

Bootstrap-specific subscription, foundation, private-endpoint, and database-job
composition lives under `bootstrap/infra/` and consumes the same reviewed modules
and runtime contracts.

## Azure boundary

The Bicep modules define Container Apps, Container Registry, SQL, Service Bus, Blob
storage, Key Vault, private networking, managed identities, role assignments,
Application Insights, alerts, and the optional Azure AI Content Safety resource.

Prompt Shields use Azure AI Content Safety with local authentication disabled and
the Gateway API managed identity assigned the required data-plane role. No account
key is provisioned.

Purview policy objects are Microsoft 365 tenant resources and are not created by
Azure Bicep. The authorized Security & Compliance PowerShell path configures a
tenant-wide fixed `Group` location for Know Your Data and blueprint-specific
`Individual` locations for DLP. Bicep supplies only the Azure/runtime dependencies
needed by the Gateway integration.

## SQL boundary

Files under `sql/` are ordered, forward-only schema changes applied by
`tools/Gateway.DatabaseMigrator`. Empty-database initialization is allowed only
when SQL reports zero user tables. Existing environments must follow the reviewed
upgrade or recovery path; do not apply migration files manually or mark them
complete without exact database readback.

The prompt-protection and Purview-profile schema changes must exist before the
corresponding runtime features are enabled. Schema success is not inferred from a
file name, template build, or local test.

## Validation

Compile and test changes through the bootstrap/source gates and the relevant .NET
architecture and security projects. Run Azure What-If before any explicitly
authorized live deployment. Local validation never proves that an Azure resource,
tenant object, or SQL database was changed.
