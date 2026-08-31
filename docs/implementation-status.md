# Implementation status

Last updated: 2026-08-31 (Asia/Seoul).

This is the concise source-of-truth checkpoint for contributors. Public setup starts
at the repository [README](../README.md). Exact deployed development evidence is in
[the deployment status](operations/development-deployment-status.md).

## Current product state

The repository implements an N:N Gateway with:

- a role-aware Blazor Admin UI and authenticated ASP.NET Core API;
- one generated external ID and one-time-issued Gateway key per registration;
- typed reusable Agent Identity blueprint selection and compatibility recheck;
- one distinct child Entra Agent ID per registration;
- durable seven-stage provisioning on the dedicated v3 Service Bus queue;
- user-only Agent 365 Registry completion through delegated OBO;
- one-POST Registry recovery based on a creator-bound planned ID;
- final worker verification before `Active`;
- Agent 365 OTLP observability with optional Azure Monitor mirroring;
- registration-scoped data-plane idempotency under SQL application locks;
- optional Prompt Shields and Purview runtime protection;
- a resumable clean-subscription bootstrap with guided and terminal entry points.

Agent 365 Registry and several Agent Identity surfaces remain preview dependencies.
Development can explicitly enable continuous registration. Staging and production
remain closed by default.

## Bootstrap contract

`bootstrap/bootstrap.ps1` is the only supported clean-subscription engine. The root
`gateway` and `gateway.cmd` launchers provide the audience-facing experience.

Bootstrap:

1. validates tools, tenant, subscription, permissions, providers, and configuration;
2. creates one resource group and its Azure/Entra resources;
3. builds immutable images from the accepted source tree;
4. initializes only a database with zero user tables;
5. deploys the API, v3 worker, and Admin UI;
6. hardens network access;
7. verifies exact resource, image, identity, and endpoint readbacks.

Bootstrap completion does not require an Agent registration, Prompt Shields, or
Purview. Creating an Active registration is a post-deployment use check. Optional
protection-profile authority never closes ordinary unprotected registration; a
registration that selects a profile is independently validated and fails closed if
that profile is not Ready.

Bootstrap state and evidence live in ignored `.bootstrap/` paths and contain safe
identifiers only. The tool has no destroy mode. If a completed resource group was
deleted, do not replay its preserved state; use a new isolated deployment identity
or an independently reviewed recovery procedure.

## Provisioning contract

The v3 worker performs blueprint resolution, principal creation, Gateway federation,
child creation, and Agent 365 access assignment. It then waits for the signed-in
Gateway Administrator action. The API owns the Registry boundary and the worker
never calls Registry.

Before Registry creation, the API locks the job, validates the completed prefix,
acquires delegated access, and persists a creator-bound planned Registry ID. It
emits at most one POST. HTTP 201 with a safe returned ID is persisted immediately;
the planned ID is used only when a successful response omits an ID. An unknown POST
outcome permits exact GET only and never another POST.

Final verification re-reads blueprint, principal, federation, child, observability
role, and child-token mapping before setting `Active`.

## Optional protection contract

Prompt Shields is a pre-model call to Azure AI Content Safety using the API managed
identity. An allow returns a short-lived, single-use receipt bound to the request;
protected interaction ingestion requires and consumes it.

Purview runtime uses Graph v1.0 and honors activity-specific inline or offline
processing. Policy authoring has two distinct scopes:

- Know Your Data: fixed tenant-wide enterprise-AI-apps location
  `ee1680d0-702f-4090-b26c-c49091e86531`, `Group`;
- DLP: selected reusable blueprint application ID, `Individual`;
- both: `Application` enforcement plane.

Policy readback is configuration evidence only. Directory app-role assignments do
not prove the current managed-identity token contains those roles. Keep the runtime
adapter disabled until safe token-role and bounded data-plane verification pass.

## Source verification

The consolidated source gate completed on 2026-08-31:

| Verification project | Passed | Failed | Skipped |
|---|---:|---:|---:|
| Gateway.UnitTests | 632 | 0 | 0 |
| Gateway.AdminUi.Tests | 157 | 0 | 0 |
| Gateway.Setup.Tests | 131 | 0 | 0 |
| Gateway.ObservabilityRuntime.Tests | 158 | 0 | 0 |
| Gateway.ArchitectureTests | 115 | 0 | 0 |
| Gateway.IntegrationTests | 85 | 0 | 0 |
| Gateway.EndToEndTests | 102 | 0 | 0 |
| Gateway.SecurityTests | 126 | 0 | 0 |
| **.NET total** | **1,506** | **0** | **0** |

The PowerShell source gate discovered 566 tests in 22 files: 565 passed, none
failed, and one Windows-only launcher case was intentionally skipped on macOS. It
validated 17 PowerShell source files and two JSON contracts, then compiled 26 Bicep
templates and three Bicep parameter files. Release build completed with zero
warnings and zero errors; `dotnet format --verify-no-changes`, whitespace, launcher
syntax, OpenAPI YAML parsing, local documentation links, and ignored secret/state
path checks also passed.

## Known external limitations

- Preview Microsoft contracts can change or vary by tenant.
- Immediate Registry exact GET may not expose a just-created record.
- Managed-identity role changes can take time to appear in tokens.
- Purview FeatureConfiguration cmdlets are Public Preview and are not available in
  every organization.
- `downloadText` may be offline; do not claim response-side inline enforcement.
- Local tests and policy readback are not live deployment or provider-verdict proof.

## Safe resume point

For source work, start with the current worktree and rerun the smallest affected
tests before broader gates. For any authorized Azure, Entra, SQL, Graph, Purview, or
deployment action, first read the deployment status and relevant runbook. Preserve
ignored bootstrap state and never read or print `.secret`/`.secrets` values.

The next user-operated deployment must follow the public README with a new unused
deployment identity. Codex must not run that bootstrap on the user's behalf unless
the user makes a new explicit request.
