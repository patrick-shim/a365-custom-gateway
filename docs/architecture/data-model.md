# Runtime data model

PostgreSQL is the authoritative database. The current EF model contains nineteen
application tables; `GatewaySchemaVersions` records idempotent runtime upgrades.
Startup creates a fresh model or applies the known connector schema upgrade under
a PostgreSQL advisory lock. Existing schemas must match the model; unsupported
schema adoption is rejected. See the
[database integration checks](../../tests/README.md).

## Registration and provisioning

`AgentRegistrations` contains the external identifier, lifecycle, requested and
resolved blueprint, individual agent identity, Registry registration identifier,
feature selection and protection revision. Filtered unique indexes prevent
active registrations from sharing external or identity bindings.
`AgentFeatureConfigurations` holds each agent's runtime choices.

`ProvisioningJobs` and `ProvisioningJobSteps` persist the current seven-step
workflow: resolve blueprint, ensure blueprint principal, configure gateway
federation, create agent identity, assign Agent 365 access, register the agent,
and verify the connection. Each step resumes only from verified saved identifiers.
Credentials do not belong in serialized provisioning state.

`AgentIngressCredentials` stores gateway API credential metadata and hashes.
Runtime blueprint credential material is held in ignored bootstrap secret
storage, independently from the ingress credentials.

## Policy assignment and prompt decisions

`AgentPolicyAssignments` references one registration and records the individual
agent identity, selected existing Purview policy, reviewed definition revision,
actor, confirmation window, assignment result and failure information. The foreign
key rejects orphan assignments. The policy definition and classifier/rule content
remain in Purview; shared blueprint profiles are not stored in this database.

`PurviewConnectorStates` records one tenant's stable local connector identity,
six-state lifecycle, manual refresh mode, heartbeat, last attempt/success,
accepted-catalog time and counts, current operation, sanitized failure/correlation
data, and optimistic row version. `PurviewConnectorOperations` stores each Connect
or RefreshCatalog request with its exact idempotency/request hash, generation,
lease/deadline, progress, terminal result hash, and audit identity.
`PurviewCatalogSnapshots` stores immutable accepted catalog JSON plus tenant,
connector, operation, monotonic generation, canonical hash, retrieval/acceptance
times, and counts. Policy listing and assignment review use this accepted database
snapshot; connector transport files are never the ongoing authority.

`PromptEvaluationRecords` binds each evaluation to its registration, protection
revision, context digest and effective requirements. PostgreSQL row locks protect
the registration and features during receipt validation. A changed protection
context invalidates a previous receipt. A current authenticated individual-policy
scope readback is required when Purview evaluation is enabled.

`AiInteractionRecords` and `PurviewDecisions` persist interaction and decision
metadata. `ActivityReceipts` tracks activity submissions. Content storage is
S3-compatible storage; authorization and retention follow the ingress contracts.

## Coordination and settings

`OutboxMessages` provides durable publication to the provisioning worker queue.
Claims use an atomic PostgreSQL update with `FOR UPDATE SKIP LOCKED`; lease
coordinates prevent stale publishers from changing a newer claim.
`IdempotencyRecords` protects ingress retries. `IngressRateLimitBuckets` provides
shared credential, agent and global limits across replicas.

`SystemConfigurations` holds supported gateway defaults and limits.
`SystemConfigurationMutations` records settings request hashes and results under
a tenant/idempotency-key unique constraint. `AuditEvents` records administrative
activity. Integration readiness is derived from configured runtime credentials and
durable confirmed individual-agent policy evidence. Display-catalog age does not
expire a binding. A refresh-proven removal, revision, compatibility, or exact-
target change marks the assignment `NeedsAttention` and advances only the affected
registration's protection revision.

Concurrency tokens are application-generated binary values persisted in
PostgreSQL. Constraint and index declarations use native PostgreSQL SQL.
The database regression suite checks schema/model parity, the connector schema
upgrade, concurrent creation, orphan rejection, distributed limits, outbox claims,
idempotency and receipt transactions against a newly created disposable database.
