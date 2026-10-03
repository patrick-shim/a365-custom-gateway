# Gateway documentation

Start with the **[product brief](spec/product-brief.md)** for objective, scope,
features, expected behaviors, and the non-negotiable split:

- **Essential product services:** Entra, Graph, Agent 365, Purview, Prompt Shields  
- **Infrastructure:** zero Microsoft dependence (PostgreSQL, RabbitMQ, Vault/OpenBao,
  S3, Compose/Kubernetes on AWS/GCP/on-prem)  
- **UI:** React + Fluent for all UIs; C# backend

## Product and use

| Need | Guide |
|---|---|
| Objective, scope, features, behaviors, platforms | [Product brief](spec/product-brief.md) |
| UI stack and design system (Console + Setup) | [UI design](console/design.md) · [Console README](../web/console/README.md) |
| Portable runtime and components | [System architecture](architecture/system-architecture.md) |
| Build, install, connect an agent | [Project README](../README.md) |
| Portable Compose E2E (auth, FMI, Registry, Active) | [Portable profile handoff](portable/README.md) |
| Installer commands and deploy profiles | [Bootstrap](../bootstrap/README.md) |
| Compose files / ports | [deploy/portable](../deploy/portable/README.md) |
| Infrastructure profiles (portable vs legacy Azure) | [Infrastructure](../infrastructure/README.md) |
| Existing-installation operation and recovery | [Operations](../operations/README.md) |
| Legacy Azure-profile maintenance | [Upgrade contract](../operations/gateway-upgrade.md) |

## Architecture and integration

| Need | Guide |
|---|---|
| Persistence, messaging, and receipts | [Data model](architecture/data-model.md) |
| Protection configuration and runtime proof | [Protection architecture](architecture/protection-settings-plan.md) |
| Windows Purview execution and packaging | [Windows executor](architecture/purview-windows-executor.md) |
| Microsoft provider contracts (Entra/Graph/Registry/Purview) | [Microsoft capabilities](architecture/microsoft-capabilities.md) |
| HTTP authorization and lifecycle rules | [API contract](api/api-contract.md) |
| Machine-readable HTTP schemas | [OpenAPI](api/openapi.yaml) |

These guides describe source behavior and its boundaries. A configuration file,
historical receipt, successful build, or health response is not proof that a
different deployment or provider operation completed successfully.

Legacy Blazor/Setup UI and Azure infrastructure templates may still appear in
source; they are **not** the long-term runtime. Entra / Graph / Agent 365 /
Purview / Prompt Shields remain **essential product services**, never confused
with infrastructure.
