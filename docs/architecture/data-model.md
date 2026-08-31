# Data model

Azure SQL is the authoritative store for Gateway registrations, provisioning,
credentials, idempotency, audit, and outbox state. The schema is applied by reviewed
migrations and bootstrap initializes only a database with zero user tables.

## Core relationships

```mermaid
erDiagram
    AGENT_REGISTRATIONS ||--o{ PROVISIONING_JOBS : owns
    PROVISIONING_JOBS ||--o{ PROVISIONING_JOB_STEPS : contains
    AGENT_REGISTRATIONS ||--|| AGENT_FEATURE_CONFIGURATIONS : configures
    AGENT_REGISTRATIONS ||--o| AGENT_CREDENTIAL_REFERENCES : references
    AGENT_REGISTRATIONS ||--o{ AGENT_INGRESS_CREDENTIALS : authenticates
    AGENT_REGISTRATIONS ||--o{ ACTIVITY_RECEIPTS : records
    AGENT_REGISTRATIONS ||--o{ IDEMPOTENCY_RECORDS : scopes
    AGENT_REGISTRATIONS ||--o{ PROMPT_EVALUATION_RECORDS : protects
    AGENT_REGISTRATIONS }o--|| PURVIEW_POLICY_PROFILES : optionally_uses
```

`OutboxMessages` is a transactionally written dispatch table whose payload carries
safe workflow identifiers; the current schema does not model a foreign key from it
to a job or registration.

## Registration aggregate

`AgentRegistrations` binds the generated external agent ID, selected reusable
blueprint, distinct child Agent ID, accepted Registry ID, feature settings, status,
and timestamps. One external ID maps to exactly one registration. A blueprint may
be reused by many registrations; a child identity may not.

`AgentIngressCredentials` stores key ID, format and hash metadata, salted verifier,
creation time, required expiry, revocation time, and the creating administrator's
object ID. It never stores the clear Gateway key. `AgentCredentialReferences` is a
separate one-to-one registration reference used by the provisioning aggregate.

## Provisioning state

`ProvisioningJobs` owns ordered `ProvisioningJobSteps`. The current workflow uses
seven steps selected from the persisted `ProvisioningStepType` enum. Existing enum
numeric values are compatibility contracts and must not be reordered or reused.

The API-owned `Agent365RegistryAttemptState` is serialized into the `RegisterAgent`
step's `ResultData`; there is no separate Registry-attempt table. It records the
authentication mode, creator, start time, planned Registry ID, and optional returned
Registry ID. It is distinct from the historical serialized compatibility property
on worker state. Only this API-owned step state authorizes Registry recovery.

```mermaid
stateDiagram-v2
    [*] --> Pending
    Pending --> Running
    Running --> AwaitingAdministratorAction
    AwaitingAdministratorAction --> Running: accepted administrator action
    Running --> Completed: final verification succeeds
    Running --> Failed
    Running --> RequiresManualIntervention
    AwaitingAdministratorAction --> RequiresManualIntervention
```

Registry acceptance and final verification are step-level facts while the job is
`Running`; they are not additional `JobStatus` values.

An unknown POST outcome does not return to a POST-capable state. Recovery performs
exact GET against the persisted planned ID or remains manual.

## Idempotency and locking

Data-plane idempotency is scoped by registration, normalized endpoint, and canonical
UUIDv4 idempotency key. Under a transaction-owned SQL application lock, the API:

1. resolves the authenticated registration;
2. computes a canonical request hash;
3. acquires the scoped lock;
4. reads or creates the idempotency lease;
5. performs side effects and outbox writes;
6. commits safe response metadata.

The same key and hash replay the safe recorded result. The same key with a different
hash returns conflict before side effects. One-time secret responses are never
cached for replay.

## Outbox

`OutboxMessages` is written in the same SQL transaction as the state transition.
Publishers deliver to Service Bus and mark dispatch state afterward. Consumers must
tolerate duplicate delivery. Final Registry acceptance enqueues only the final
verification message.

## Content and observability metadata

Raw approved interaction content is kept only in the encrypted Blob content store
with documented retention. SQL activity receipts contain sanitized identifiers,
processing decisions, timestamps, and correlation data. Prompt-evaluation receipts
store a salted content binding and consumption state, never the prompt.

## Purview profiles

`PurviewPolicyProfiles` represents reusable Gateway-managed policy configuration.
Its effective scopes are deliberately different:

- Know Your Data: one tenant-wide fixed enterprise-AI-apps Group location;
- DLP: one or more reviewed blueprint application IDs as Individual locations.

Profile assignment is optional. A registration without a profile follows the core
path. A registration that selects one fails closed unless the profile and its
independent provider readback are Ready.

## Retention and deletion

The idempotency service applies the configured idempotency-record lifetime when it
creates a record. The repository does not currently implement background cleanup
for activity receipts, audit events, or outbox rows, so their persisted legacy
retention columns are not presented as active controls. Identity, Registry, and
credential cleanup are separate privileged operations and must be based on exact
ownership evidence. Bootstrap intentionally has no destroy mode.
