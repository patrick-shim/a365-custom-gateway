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
  private-key proof with both documented null and empty password encodings,
  without certificate-store fallback.

- Bootstrap capability verification uses ARM's exact `True`/`False` environment
  text, with executable coverage for both values and fail-closed mismatches.

- The legacy protection scope constraint matches SQL Server catalog serialization
  while preserving AND-before-OR semantics and strict bootstrap schema verification.

- Resume after completed automatic database recovery separately binds its corrected
  execution snapshot while preserving original plan and workload provenance.

- Credential deployment validates corrected execution snapshots before identity
  mutation and preserves original resource provenance through recovery.
- Final verification checks Purview roles on the shared runtime identity and
  retains the separate exact API and worker role sets.

### Validation boundary

- Release: zero warnings/errors; all eight .NET projects: 2,004 passed;
  canonical Pester: 846 passed, zero failed, 7 skipped. All nine format
  targets, source/Bicep, metadata/parity, and full-ledger checks passed.
- Fresh independent security and UI source review passed with no remaining
  actionable findings. Desktop/narrow browser inspection was explicitly waived
  in favor of bUnit and independent source review after browser policy blocked it.
- Clean export passed Release, all eight test projects, canonical bootstrap
  source/Pester/Bicep, layout, and launcher smoke with all intended new files.
- Certificate-test portability corrections passed 11 affected tests in the
  canonical checkout and clean export, plus fresh independent review. Synthetic
  fixtures cover all eight null/empty password encoding combinations and reject
  nonempty-password and public-only packages. The preceding hosted run passed
  .NET, Bicep, Ubuntu, and macOS; all five jobs subsequently passed for the final
  Windows proof correction before the authorized live attempt.
- The authorized live bootstrap stopped at inert verification after ARM succeeded.
  The capability-Boolean correction passes 14 focused tests, all 2,004 .NET tests,
  Release, independent review, and read-only inert verification. The complete
  correction gate passed 848 Pester tests with zero failures and 7 skips plus
  source/Bicep. Clean export passed Release, 2,004 .NET tests, source/Bicep,
  regression and launcher smoke; all nine format and metadata checks passed.
  All five hosted jobs passed for the corrective commit.
- A separately authorized replacement passed inert verification and ten bootstrap
  stages, then stopped at exact SQL schema comparison after EF schema creation.
  The original SQL administrator was independently verified restored. Both
  deployment states and the one failed database execution are preserved. Schema
  comparison and regression coverage identify the model and Resume corrections.
  Combined correction acceptance passed fresh independent review, Release, all
  2,005 .NET tests, 871 Pester tests (zero failures, 7 skips), source/Bicep, all
  nine format targets, metadata/private-path checks, full ledger audit, and the
  clean 900-file export with launcher smoke. Exact-commit hosted CI precedes
  bounded recovery;
  Admin UI deployment and live registration/protection E2E remain unproved.
  Git transfers no live authority.


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
