# A365 Custom Gateway product brief

This document describes the retained working application's purpose and intended
user outcomes. Development acceptance is recorded only in the
[milestone checklist](../../MILESTONES.md); [project state](../project-state.md)
records current tooling availability and the next action.

## Purpose

The A365 Custom Gateway gives tenant administrators one place to connect
independently hosted AI agents to Microsoft Agent 365 identity, observability,
and optional data protection. It deploys and operates the Gateway; each external
agent retains its own hosting and model calls.

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
7. configure the external agent to evaluate every prompt before calling its own
   model, then submit activity and the completed interaction with that evaluation
   receipt.

The guided installer is the intended product entry point. Re-establishing its
deleted supporting tool projects and the test harness is part of the milestone
plan; these audience outcomes are not a claim of a currently verified fresh install.

An operator should inspect health, registrations, operations, credential lifecycle,
and safe correlation evidence without seeing secrets or content.

## Product boundaries

- Gateway owns its ingress credential model; a Gateway key is not a Microsoft
  identity credential.
- Every registration maps to one reusable blueprint and one distinct child Agent ID.
- The retained Registry integration uses the beta API and admits only explicitly
  acknowledged development use; staging and production remain closed. Provider
  availability and support must be revalidated during deployment planning.
- Bootstrap prepares and verifies deployment capabilities. The deployed Gateway
  owns registrations and ongoing protection configuration. Registration/editing
  can include explicitly reviewed Purview configuration; a new blueprint's
  configuration waits for that exact blueprint to finish registration.
- Agent 365 observability is the default telemetry destination; Azure Monitor
  mirroring is optional.
- Prompt Shields and Purview are independent optional controls.
- Current fresh-setup configuration includes shared Azure AI Content Safety;
  per-agent Prompt Shields use is selected separately. Legacy capability choices
  remain part of source-bound recovery contracts.
- Purview DLP protects a reusable blueprint; Know Your Data collection is a
  separate tenant-wide fixed Group contract.
- Agent 365 beta admission is deployment-wide. Quick development may default it on
  only with explicit acknowledgement; staging and production remain closed.
- The Gateway does not proxy the external model call or claim response blocking
  when Microsoft returns offline processing.
- Purview configuration supports Enforce, SimulationWithTips,
  SimulationWithoutTips and Disabled. Simulation does not establish enforcement
  readiness, and saved configuration does not replace current runtime evidence.
- Removing a Gateway registration preserves its linked Microsoft resources.

## Quality attributes

### Security

- least-privilege managed identity and delegated user access;
- Entra-only SQL authentication and private network boundaries;
- one-time Gateway keys stored only as salted verifiers;
- no secrets, tokens, prompts, responses, or provider bodies in logs, queues or
  operational checkpoint state; interaction content belongs in its designated
  protected content store;
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
- clear credential, operation and protection journeys with actionable failure
  recovery;
- current guides for the operational entry points that exist in the repository.

The deployment command succeeds only after exact Azure, Entra, database, image,
identity, and endpoint readbacks. A later Active registration demonstrates the
tenant-specific provisioning path completed its final Gateway verification. Neither
result is generalized into a supported production claim for preview dependencies.

## Development quality standard

User-facing language should explain what happened, whether work is continuing,
who must act and what to do next. Registration, installed capability, configured
policy, simulation and effective enforcement have distinct meanings. Technical
identifiers and detailed diagnostics remain available without dominating the
ordinary workflow.

Each milestone combines implementation and meaningful tests, followed by a full
documentation/directive/state/memory synchronization. A checkmark in the milestone
task list is the sole project acceptance record. Source and cloud checks are
reported only after they have actually run against the relevant version.

See the [documentation index](../README.md) and
[system architecture](../architecture/system-architecture.md).
