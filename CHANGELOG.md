# Changelog

All notable changes to A365 Custom Gateway are recorded here.

## [0.1.0-beta.1] - 2026-09-05

First public beta release candidate.

### Included

- role-aware Blazor administration and an authenticated Gateway API;
- N:N external-agent registration through reusable Agent ID blueprints, distinct
  child Agent IDs, generated external IDs, and one-time Gateway keys;
- durable seven-stage provisioning on the `gateway-provisioning-v3` queue;
- user-only Agent 365 Registry completion through delegated OBO, with a
  creator-bound one-POST recovery contract;
- strict `201 Created` Registry acceptance with exact-ID-only ambiguous recovery;
- final provider verification before a registration becomes `Active`;
- database-enforced uniqueness for each active child Agent Identity;
- registration-scoped data-plane idempotency and Agent 365 observability;
- managed-identity-only Prompt Shields and optional Microsoft Purview integration;
  and
- resumable public bootstrap launchers for Windows, macOS, and Linux.

### Beta boundaries

- Agent 365 Registry remains a beta capability that Microsoft does not support for
  production use. Agent ID creation uses documented Graph v1.0 surfaces, while
  tenant permission availability can still vary.
- Registry-backed activation is enabled only by explicit development configuration;
  staging and production remain closed by default.
- Current source is newer than the previously verified Azure deployment. Source
  validation does not prove this release tag has been deployed.
- Prompt Shields has prior live enforcement evidence. Blueprint-scoped Purview DLP
  still requires a live allow/block pair on a newly authorized deployment.
- Optional Purview inventory and policy authoring require Windows and an interactive
  Security & Compliance PowerShell sign-in.
- The restarted Setup browser Resume journey and the macOS root launcher still have
  open platform-validation checks documented in the continuation checkpoint.

See [Implementation status](docs/implementation-status.md) and
[Development deployment status](docs/operations/development-deployment-status.md)
for the exact source and live evidence boundaries.
