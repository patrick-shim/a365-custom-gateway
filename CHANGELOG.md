# Changelog

All notable changes to A365 Custom Gateway are recorded here.

## [0.1.0-beta.2] - 2026-09-06

Protection governance source release candidate.

### Changed

- Bootstrap installs shared Agent 365, Prompt Shields, and Purview capabilities
  without selecting a SIT or authoring tenant policy.
- Gateway Settings owns tenant connection, SIT selection, KYD and blueprint DLP
  administration, readiness, recovery, defaults, and per-registration controls.
- Protection operations use `gateway-protection-admin-v1`, confirmation-bound
  mutations, durable recovery, and an immutable-image Windows companion.
- Exact startup capability attestation binds API/worker runtime identity, token
  subject, provider resources, and current tenant/SIT readiness; drift fails closed.
- Purview automation terminates owned processes on cancellation and uses exact
  provider-ID-bound updates/readback. Settings submits supported DLP actions and
  limits runtime validation to enforcement mode.

- Bootstrap certificate tests use native temporary paths and in-memory PKCS12
  private-key proof on every platform, without certificate-store fallback.

### Validation boundary

- Release: zero warnings/errors; all eight .NET projects: 2,004 passed;
  canonical Pester: 846 passed, zero failed, 7 skipped. All nine format
  targets, source/Bicep, metadata/parity, and full-ledger checks passed.
- Fresh independent security and UI source review passed with no remaining
  actionable findings. Desktop/narrow browser inspection was explicitly waived
  in favor of bUnit and independent source review after browser policy blocked it.
- Clean export passed Release, all eight test projects, canonical bootstrap
  source/Pester/Bicep, layout, and launcher smoke with all intended new files.
- The first hosted run passed .NET, Bicep, and Windows but exposed certificate-test
  portability failures on Linux/macOS. The two-file correction passed 11 affected
  tests in the canonical checkout and clean export, plus independent review.
  Production source and full-suite test counts are unchanged; all hosted jobs
  must pass for the corrective commit.
- Source remains undeployed; live E2E is postponed. Hosted CI must be green for
  the exact commit, followed by fresh authorization naming an exact unused
  resource group. Git and documentation transfer no live authority.


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
