---
name: a365-provisioning
description: Implement, test, or review truthful, idempotent Entra and Agent 365 provisioning for the A365 Gateway.
---

# A365 provisioning

Read `AGENTS.md`, `CLAUDE.md`, `docs/implementation-status.md`, and
`docs/agent-guides/provisioning.md` completely before acting. Before live work,
also read the deployment status and applicable runbook.

Preserve the N:N binding: one registration maps its generated external ID and
Gateway key lifecycle to one reusable blueprint and one distinct child Agent ID.
Ordinary clients never provide managed-identity IDs or Entra tokens.

Current source uses seven stable persisted stages on `gateway-provisioning-v3`.
The worker executes blueprint resolution, principal creation, Gateway federation,
child creation, and Agent 365 access assignment, then waits at 71%. The worker never
calls Registry.

Registry completion is a signed-in `Gateway.Administrator` API action using
delegated OBO. Under the SQL job lock, the API verifies the completed prefix,
pre-acquires delegated access, persists a creator-bound planned Registry ID, and
emits at most one POST. HTTP 201 is persisted immediately. An unknown outcome uses
exact GET only and never another POST. Accepted Registry creation enqueues only
final worker verification.

The worker Graph application-role allowlist is exactly the eight roles in the shared
guide. Registry access is exactly the API app's two delegated scopes plus its
managed-identity assertion FIC. Never add app-only Registry access or a client-secret
OBO fallback.

Every provider mutation must be discoverable, idempotent, and safe after redelivery.
SQL locking is not an exactly-once claim. Keep workflow generations on separate
queues and never access/dispose of retained messages without explicit incident
authority.

Prompt Shields and Purview are optional. Profile-backed registrations fail closed
when the profile is not Ready, but optional profile authority must not close ordinary
registration. Purview policy automation keeps the fixed tenant-wide enterprise-AI-
apps Group for Know Your Data separate from blueprint Individual DLP locations; both
use the Application plane.

Use `bootstrap/bootstrap.ps1` through the root `gateway` launcher for a fresh
subscription. Preserve ignored `.bootstrap/` state and never place credentials,
tokens, keys, prompts, responses, or certificate material in configuration, logs,
tests, or chat.

Run focused tests first, then full relevant .NET, Pester, Release, source, Bicep,
formatting, and documentation gates. Local success is not deployment evidence.
