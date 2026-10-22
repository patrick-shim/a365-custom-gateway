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
verifies its access, publishes the initial verified catalog, and starts the
operation-driven runtime connector listener. Content Safety retains
its two product-resource Bicep templates. Azure hosting is not supported.

Console navigation is Agents; Data protection -> Policies; Settings -> Gateway
and Purview connection diagnostics. Each agent has separate Prompt Shields and
Data protection tabs. Settings is not another initial setup wizard. There is no
companion launch, gateway classifier editor, policy-authoring executor or Azure
package publisher. Only current policy-consumption endpoints are exposed.

## Assignment and enforcement

The accepted catalog is tenant-bound and integrity-checked in PostgreSQL. A review
binds the policy revision, administrator, agent identity and gateway protection
revision, and requires the management inventory to be within its thirty-day
mutation window. Confirmation creates a durable PostgreSQL assignment.
Authenticated request and result files connect the API to the Windows listener.
The host reads the selected policy live, preserves unrelated policy scope, and
verifies its write by reading the policy back.

Pending assignment shows an animated wait, elapsed time and last successful
status check. Completion, timeout, failure and unavailable status are distinct.
Assignment is not proof of synchronization or enforcement. The gateway calls
Graph protection scopes and processContent using the individual agent identity.
Require normal allow, synthetic-sensitive block and a same-blueprint sibling
scope check before claiming individual enforcement.

## Persistence and safety

PostgreSQL owns connector state, operations, accepted catalog snapshots, reviews,
assignments, revisions, receipts and the outbox. Runtime
coordination uses database locks across replicas. Receipt consumption is atomic
and bound to the current protection context. Unknown readiness fails closed.
Only individual assignments, accepted management evidence, and setting-mutation
records are stored; policy definitions remain owned by Purview.

The protection-context hash uses the durable individual assignment digest and
effective agent settings. Catalog retrieval and acceptance times stay outside
that identity hash. An identical accepted refresh does not break an in-flight
receipt. A refresh-proven semantic assignment/configuration change marks the
assignment `NeedsAttention`, advances the affected protection revision, and
invalidates prior evidence. Display-catalog age alone does not expire a confirmed
runtime binding; missing required live Graph evidence still fails closed.

See [policy consumption](purview-policy-consumption.md),
[catalog host](purview-catalog-host.md), and [data model](data-model.md).
