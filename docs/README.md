# Gateway documentation

## Use and operate

| Need | Guide |
|---|---|
| Build, install and connect an agent | [Project README](../README.md) |
| Console UI design system and direction | [Console design](console/design.md) · [Console README](../web/console/README.md) |
| Installer commands and prerequisites | [Bootstrap](../bootstrap/README.md) |
| Existing-installation operation and recovery | [Operations](../operations/README.md) |
| Source-bound maintenance | [Upgrade contract](../operations/gateway-upgrade.md) |
| Azure and SQL asset map | [Infrastructure](../infrastructure/README.md) |
| Product purpose and supported boundaries | [Product brief](spec/product-brief.md) |
| Supplied product specification | [Gateway specification](spec/a365-gateway-specification.pdf) |

## Architecture and integration

| Need | Guide |
|---|---|
| Components, identity and workflow | [System architecture](architecture/system-architecture.md) |
| Persistence, messaging and receipts | [Data model](architecture/data-model.md) |
| Protection configuration and runtime proof | [Protection architecture](architecture/protection-settings-plan.md) |
| Windows Purview execution and packaging | [Windows executor](architecture/purview-windows-executor.md) |
| Microsoft provider contracts | [Microsoft capabilities](architecture/microsoft-capabilities.md) |
| HTTP authorization and lifecycle rules | [API contract](api/api-contract.md) |
| Machine-readable HTTP schemas | [OpenAPI](api/openapi.yaml) |

These guides describe shipped behavior and its boundaries. A configuration file,
historical receipt, successful build or health response is not proof that a
different deployment or provider operation completed successfully.
