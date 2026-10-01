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
| Design journeys, wording, screens and acceptance scenarios | [UX design package](ux/README.md) |

The milestone task checkmarks are the sole completion record. Guides describe
current source behavior and prerequisites; they do not maintain separate pass
counts or deployment-completion claims. Every milestone requires a review and
synchronization of the entire project's documents, directives, state and memory.

The UX design package is the M3/M4 design reference. The guides below describe
current onboarding, handoff, listing, focused protection tasks, explained outcomes,
bounded read-only progress, exact-profile continuation, expiry-aware summaries
and approved-sample behavior. Same-page shortcuts preserve recovery context;
pre-submission browser failures are distinguished from uncertain submitted work.
The novice setup guide separates count-only connection inventory, one policy SIT
selection and explained defaults, while preserving draft values. Native reads
are bounded and exact-policy recovery requires fresh reviewed inventory binding;
visible activity never substitutes for provider evidence.
Implementation is not milestone or live
acceptance. The local prototype remains separate from production components and
their regression fixtures; release and hosted verification retain their own scope.

## Build, deploy and operate

| Need | Document |
|---|---|
| Installer commands, configuration and prerequisites | [Bootstrap guide](../bootstrap/README.md) |
| Azure templates and SQL assets | [Infrastructure map](../infrastructure/README.md) |
| Operational commands and test classification | [Operations guide](../operations/README.md) |
| Existing-deployment upgrade contract | [Upgrade guide](../operations/gateway-upgrade.md) |
| Earlier maintenance scaffold and its limits | [Maintenance guide](../operations/gateway-maintenance.md) |

Supporting tools/tests and the original Azure resources were deliberately removed.
Authored tooling, local fixtures and an isolated release-qualification installation
are now present; their actual acceptance belongs to M5. M6's hosted product and
provider journeys remain separate. Use the
[local baseline command](../README.md#local-source-and-behavioral-validation)
without treating its result as cloud acceptance. Existing checkpoint-bound recovery
code describes an intact deployment; it does not reconstruct the deleted environment.

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
