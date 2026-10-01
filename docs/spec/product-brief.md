# A365 Custom Gateway product brief

This document describes the application's purpose, user outcomes and supported
product boundaries.

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
7. securely store the key, complete the delegated Registry handoff, and wait for
   final registration verification;
8. configure the external agent to evaluate every prompt before calling its own
   model, then submit activity and the completed interaction with that evaluation
   receipt.

The guided installer is the product entry point. Infrastructure health and
runtime startup are prerequisites, not proof of these complete user journeys.

An operator should inspect health, registrations and provisioning operations,
enable or disable agent access, and identify actions requiring an administrator.
Credential management remains administrator-only. Auditors can inspect audit
history; support readers can inspect permitted registration and capability state.
The external developer integrates one registration through its Gateway key.

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

The application includes reviewed registration/key handoff, bounded recovery,
agent paging and sample-result handling, focused protection tasks, expiry-aware
summaries and approved runtime-sample workflows. Source implementation alone
does not establish release or provider acceptance; authorization and recovery
contracts must hold in the selected deployment.

Every protection outcome explains what happened, why it was needed, what remains
unverified and the next permitted action. A technical Completed/Skipped timeline
alone is not an acceptable end to the journey. Bounded read-only progress updates
and exact-context next-step links must not auto-confirm, replay work or silently
enable protection. Registration, installed capability, configured
policy, simulation and effective enforcement have distinct meanings. Technical
identifiers and detailed diagnostics remain available without dominating the
ordinary workflow.

First-time protection setup follows a visible ordered guide. Connection reports
available types without a misleading selection step; policy types are selected
once, with explained adjustable defaults and preserved saved/draft values.
Subtle accessible activity identifies real pending UI work or status checks,
including reduced-motion and paused states, without inventing provider progress.
This source retains Blazor: the identified gaps are workflow/state/provider
behavior, not evidence that a framework replacement is required.

Source and cloud checks are reported only after they have run against the exact
relevant version. Product documentation must remain consistent with the API,
permissions and observed behavior.

See the [documentation index](../README.md) and
[system architecture](../architecture/system-architecture.md).
