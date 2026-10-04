# Product brief

A365 Custom Gateway connects independently hosted agents to Microsoft identity, governance and observability. The agent retains its own model and hosting. The gateway supplies per-agent registration, credentials, pre-model evaluation, interaction/activity intake and administrative visibility.

## Responsibilities

| User | Responsibility |
| --- | --- |
| Deployer | Configure tenant access, Content Safety and Purview during terminal or React bootstrap; review provisioning changes |
| Gateway administrator | Register agents, confirm Registry registration, manage keys and protections, select existing Purview policies for individual identities |
| Purview policy owner | Author classifiers, sensitive information types, rules, actions, policy mode and exclusions in Purview |
| Agent developer | Evaluate before invoking the model, honor blocks/unavailable results, consume the matching receipt and send activities |

The Console contains Agents, Data protection / Policies, and Settings / Gateway and Purview diagnostics. Agent details separate Prompt Shields, Data protection, identity, API credentials and activity. Initial connection setup belongs to bootstrap. Terminal and React setup use the same configuration and provisioning engine.

## Identity and protection

A blueprint is reusable; each registered agent has a distinct individual identity. Selecting a policy adds that identity to its application locations while preserving other scope and rules. It does not select the blueprint or remove other applicable policies. Assignment, provider propagation and verified enforcement are separate states.

Registration is an asynchronous workflow. A signed-in administrator confirms the existing identity's Registry registration using delegated access. A provisioning response is not an Active readback. Clear gateway keys are returned once, with revocation managed separately from registration.

Prompt evaluation runs before the external model. Required protection errors fail closed; only a valid allow receipt permits the model/interaction sequence. A receipt binds exact content and context to the current protection configuration. Telemetry acceptance does not guarantee visibility in each Microsoft destination.

## Implementation and limits

The current implementation uses C#/.NET 10, React/Fluent UI, PostgreSQL, RabbitMQ, Vault and S3-compatible storage on Docker Compose, plus a Windows Purview certificate host. Registry beta is an explicitly acknowledged development capability. The local Compose defaults are development settings, not a production-hardening claim.

The gateway does not host models, author Purview policies or classifiers, or interpret a successful policy-scope write as proven blocking. Normal allow, sensitive block, sibling scope and remote telemetry visibility require separate verification.

See the [project overview](../../README.md), [architecture](../architecture/system-architecture.md), [API contract](../api/api-contract.md) and [runtime guide](../runtime/README.md).
