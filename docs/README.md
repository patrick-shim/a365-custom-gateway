# A365 Custom Gateway documentation

The project connects independently hosted agents to Agent 365 identity,
observability and optional protection. The retained application is the working
baseline for the development plan.

## Start here

| Need | Document |
|---|---|
| Product purpose and everyday use | [Project README](../README.md) |
| Milestones, task acceptance and completion | [Milestone checklist](../MILESTONES.md) |
| Next action and current source context | [Project state](project-state.md) |
| Agent working rules | [Agent directives](../AGENTS.md) |
| Persistent project preferences | [Repository memory](../MEMORY.md) |
| Audience outcomes and product boundaries | [Product brief](spec/product-brief.md) |

The milestone task checkmarks are the sole completion record. Guides describe
current source behavior and prerequisites; they do not maintain separate pass
counts or deployment-completion claims. Every milestone requires a review and
synchronization of the entire project's documents, directives, state and memory.

## Build, deploy and operate

| Need | Document |
|---|---|
| Installer commands, configuration and prerequisites | [Bootstrap guide](../bootstrap/README.md) |
| Azure templates and SQL assets | [Infrastructure map](../infrastructure/README.md) |
| Operational commands and test classification | [Operations guide](../operations/README.md) |
| Existing-deployment upgrade contract | [Upgrade guide](../operations/gateway-upgrade.md) |
| Earlier maintenance scaffold and its limits | [Maintenance guide](../operations/gateway-maintenance.md) |

Supporting tools/tests and related Azure resources were deliberately removed.
Read the source-availability notes in these guides before using an installer or
operational command. Existing checkpoint-bound recovery code describes recovery
for an intact deployment; it does not reconstruct the deleted environment.

## Architecture and integration

| Need | Document |
|---|---|
| Components, identity and workflow | [System architecture](architecture/system-architecture.md) |
| Persistence, messaging and receipt consistency | [Data model](architecture/data-model.md) |
| Protection capabilities and administration | [Protection architecture](architecture/protection-settings-plan.md) |
| Windows Purview execution and packaging | [Windows executor](architecture/purview-windows-executor.md) |
| Microsoft provider contracts used by this source | [Microsoft capabilities](architecture/microsoft-capabilities.md) |
| API authorization, lifecycle and client behavior | [API contract](api/api-contract.md) |
| Machine-readable HTTP schemas | [OpenAPI](api/openapi.yaml) |

## Documentation maintenance

At milestone closure inspect every authored Markdown file plus relevant
configuration/schema contracts. Update changed behavior, links, entry points and
prerequisites, and review unchanged sections for consistency. Update the next
action in project state and preserve user preferences in repository memory. Check
the milestone synchronization task only after that whole-project review passes.
