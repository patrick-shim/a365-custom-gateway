# Gateway documentation

Start with the **[product brief](spec/product-brief.md)** for objective, scope,
features, expected behaviors, and the **UI platform requirement** (React + Fluent
for all UIs; C# backend). UI details live in the
**[UI design system](console/design.md)**.

## Product and use

| Need | Guide |
|---|---|
| Objective, scope, features, behaviors, UI platform | [Product brief](spec/product-brief.md) |
| UI stack, design system, Console + Setup direction | [UI design](console/design.md) · [Console README](../web/console/README.md) |
| Build, install, connect an agent | [Project README](../README.md) |
| Installer commands and prerequisites | [Bootstrap](../bootstrap/README.md) |
| Existing-installation operation and recovery | [Operations](../operations/README.md) |
| Source-bound maintenance | [Upgrade contract](../operations/gateway-upgrade.md) |
| Azure and SQL asset map | [Infrastructure](../infrastructure/README.md) |

## Architecture and integration

| Need | Guide |
|---|---|
| Components, identity, and workflows | [System architecture](architecture/system-architecture.md) |
| Persistence, messaging, and receipts | [Data model](architecture/data-model.md) |
| Protection configuration and runtime proof | [Protection architecture](architecture/protection-settings-plan.md) |
| Windows Purview execution and packaging | [Windows executor](architecture/purview-windows-executor.md) |
| Microsoft provider contracts | [Microsoft capabilities](architecture/microsoft-capabilities.md) |
| HTTP authorization and lifecycle rules | [API contract](api/api-contract.md) |
| Machine-readable HTTP schemas | [OpenAPI](api/openapi.yaml) |

These guides describe source behavior and its boundaries. A configuration file,
historical receipt, successful build, or health response is not proof that a
different deployment or provider operation completed successfully. Legacy Blazor
and Setup UI details may appear until React cutover completes; they are not the
long-term product UX.
