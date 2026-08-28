# Operational scripts

This directory contains reviewed scripts for an existing Gateway environment. It is
not the day-zero installation entry point; use
[`../bootstrap/README.md`](../bootstrap/README.md) for a fresh subscription or a
deleted resource group.

| Script | Purpose |
|---|---|
| `deploy.ps1` | Deploy current workload Bicep to an existing foundation. |
| `test-provisioning-prerequisites.ps1` | Run fail-closed, read-only provisioning preflight checks. |
| `invoke-development-canary.ps1` | Run the bounded development canary workflow described by the runbooks. |
| `setup-sql-user.ps1` | Configure reviewed SQL workload principals. |
| `bootstrap-provisioning-worker.ps1` | Narrow legacy worker bootstrap/recovery helper; not the repository bootstrap entry point. |

The scripts consume templates from [`../infrastructure/`](../infrastructure/README.md)
and must follow the current checkpoint in
[`../docs/operations/development-deployment-status.md`](../docs/operations/development-deployment-status.md).
Run read-only preflight or Bicep what-if before any authorized mutation. Never infer
live readiness from a successful local invocation, and never print or persist secret
runtime input.
