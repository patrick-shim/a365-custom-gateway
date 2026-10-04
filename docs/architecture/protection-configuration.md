# Protection configuration

## Product ownership

Purview policy administrators own classifiers, sensitive information types,
rules, thresholds, actions and policy modes in Purview. Gateway administrators
select existing compatible policies and assign exact individual agent identities.
An assignment preserves unrelated targets and exclusions and never substitutes
the shared blueprint for an individual agent.

## Installation and administration

TUI and React Setup collect Content Safety and Purview choices during bootstrap.
They use the same validation, plan, provisioning and verification engine.
Bootstrap provisions the dedicated Purview management identity and certificate,
verifies its access, and starts the runtime catalog host. Content Safety retains
its two product-resource Bicep templates. Azure hosting is not supported.

Console navigation is Agents; Data protection -> Policies; Settings -> Gateway
and Purview connection diagnostics. Each agent has separate Prompt Shields and
Data protection tabs. Settings is not another initial setup wizard. There is no
companion launch, gateway classifier editor, policy-authoring executor or Azure
package publisher. Only current policy-consumption endpoints are exposed.

## Assignment and enforcement

The catalog is signed, tenant-bound and freshness-checked. A review binds the
policy revision, administrator, agent identity and gateway protection revision.
Confirmation creates a durable PostgreSQL assignment. Authenticated request and
result files connect the API to the Windows catalog host. The host preserves
unrelated policy scope and verifies its write by reading the policy back.

Pending assignment shows an animated wait, elapsed time and last successful
status check. Completion, timeout, failure and unavailable status are distinct.
Assignment is not proof of synchronization or enforcement. The gateway calls
Graph protection scopes and processContent using the individual agent identity.
Require normal allow, synthetic-sensitive block and a same-blueprint sibling
scope check before claiming individual enforcement.

## Persistence and safety

PostgreSQL owns reviews, assignments, revisions, receipts and the outbox. Runtime
coordination uses database locks across replicas. Receipt consumption is atomic
and bound to the current protection context. Unknown readiness fails closed.
Only current individual assignments and setting-mutation records are stored.

See [policy consumption](purview-policy-consumption.md),
[catalog host](purview-catalog-host.md), and [data model](data-model.md).
