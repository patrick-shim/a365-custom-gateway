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
binds the client-submitted public whole-scope `revision`, administrator, agent
identity, and gateway protection revision, and stores it in `ReviewedRevision`.
The accepted inventory has no age expiry and remains usable until manual sync
replaces it; connector availability does not invalidate the cached selection.
Confirmation creates a durable PostgreSQL assignment; successful signed readback
stores internal `definitionRevision` in `AssignedRevision`.
Authenticated request and result files connect the API to the Windows listener.
The host reads the selected policy live, preserves unrelated policy scope, and
verifies its write by reading the policy back.

The public revision preserves the deployed legacy algorithm, including provider
policy/rule timestamps and legacy array behavior. The internal revision
excludes locations, provider timestamps, and policy display name, sorts only known
outer set-like collections, and preserves unknown nested-array order.

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
effective agent settings. Catalog times and public whole-scope `ReviewedRevision`
stay outside that identity hash. An identical accepted refresh or separately
reviewed addition of another exact identity does not break an existing agent's
in-flight receipt. A changed internal `AssignedRevision`, removal or
narrowing/exclusion of that agent's exact all-accounts target, or incompatibility
marks its assignment `NeedsAttention`, advances its protection revision, and
invalidates prior evidence. Display-catalog age alone does not expire a confirmed
runtime binding; missing required live Graph evidence still fails closed.

See [policy consumption](purview-policy-consumption.md),
[catalog host](purview-catalog-host.md), and [data model](data-model.md).
