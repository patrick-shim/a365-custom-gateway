# A365 Custom Gateway product brief

## Purpose

The A365 Custom Gateway gives tenant administrators one place to configure, deploy,
and operate independently hosted AI agents with Microsoft Agent 365 identity,
observability, and optional data protection.

It serves organizations that own Azure and Microsoft 365 tenants but run agents
outside Microsoft hosting. Ordinary external agents do not manage Entra credentials.

## Audience outcomes

An administrator should be able to:

1. clone the repository;
2. run one guided setup command;
3. review subscription, tenant, permissions, and optional features;
4. deploy a verified Gateway and open its Admin UI;
5. register an external agent against a compatible reusable blueprint;
6. receive the external ID and one-time Gateway key;
7. configure the agent to submit activity, interaction, and optional prompt
   evaluation traffic.

An operator should inspect health, registrations, operations, credential lifecycle,
and safe correlation evidence without seeing secrets or content.

## Product boundaries

- Gateway owns its ingress credential model; a Gateway key is not a Microsoft
  identity credential.
- Every registration maps to one reusable blueprint and one distinct child Agent ID.
- Agent 365 Registry is a preview dependency and remains closed by default outside
  explicitly acknowledged development use.
- Bootstrap deploys and verifies the core Gateway. Registrations and optional
  protections are post-deployment tasks.
- Agent 365 observability is the default telemetry destination; Azure Monitor
  mirroring is optional.
- Prompt Shields and Purview are independent optional controls.
- Purview DLP protects a reusable blueprint; Know Your Data collection is a
  separate tenant-wide fixed Group contract.
- The Gateway does not proxy the external model call or claim response blocking
  when Microsoft returns offline processing.

## Quality attributes

### Security

- least-privilege managed identity and delegated user access;
- Entra-only SQL authentication and private network boundaries;
- one-time Gateway keys stored only as salted verifiers;
- no secrets, tokens, prompts, responses, or provider bodies in logs or state;
- exact tenant, subscription, resource, and operation bindings;
- fail-closed behavior for unknown provider outcomes.

### Reliability

- durable SQL workflow state and transactional outbox;
- duplicate-safe Service Bus handling;
- discover-before-create provider operations;
- one Registry POST with exact-ID recovery;
- resumable bootstrap checkpoints and immutable image evidence.

### Operability

- guided setup plus terminal commands;
- health/readiness endpoints and role-aware Admin UI;
- RFC 9457 errors with safe correlation IDs;
- current runbooks for verification, recovery, upgrades, credential rotation, and
  incidents.

The deployment command succeeds only after exact Azure, Entra, database, image,
identity, and endpoint readbacks. A later Active registration demonstrates the
tenant-specific provisioning path completed its final Gateway verification. Neither
result is generalized into a supported production claim for preview dependencies.

See the [documentation index](../README.md) and
[system architecture](../architecture/system-architecture.md).
