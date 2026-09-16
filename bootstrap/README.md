# Gateway bootstrap

The root `gateway` and `gateway.cmd` launchers are the canonical installation
entry points. Their retained PowerShell engine coordinates configuration, Azure
What-If, reviewed deployment, identity preparation, database initialization,
workload deployment and verification. Individual modules and templates are inputs
to that lifecycle, not alternate installers.

## Current source boundary

The user deliberately removed supporting files and related Azure resources. The
retained application remains the working baseline, but the complete installer is
**not yet revalidated runnable**. The launchers reference absent
`tools/Gateway.Setup`; database deployment references absent
`tools/Gateway.DatabaseMigrator`; the solution also references absent
`tools/Gateway.LiveVerification`. The former `tests/` projects are absent.
Generated binaries do not replace these source prerequisites.

[MILESTONES.md](../MILESTONES.md) is the only completion record. M1 covers the
missing tooling and reproducible tests; later milestones cover a new deployment.
[AGENTS.md](../AGENTS.md) defines the pinned tenant/subscription, Chrome preference
and persistent user authorization. Existing configuration, ignored operational
state and incident-specific scripts do not prove a current installation.

## Intended installation

Once the missing sources and entry points pass their milestone validation, the
intended guided commands are:

```bash
./gateway setup
```

```powershell
.\gateway.cmd setup
```

The `setup` launcher starts the local Setup project. Because that project is
absent, its previous screen behavior is not treated as a currently verified UI.
The retained terminal lifecycle is:

```text
doctor → init → plan → apply → verify
                       ↘ resume after an eligible interruption
```

This is a workflow description, not an instruction to resume a deleted
environment. Do not invoke deployment to discover missing build inputs.

## Prerequisites and configuration

Build inputs include Git, the .NET SDK selected by [global.json](../global.json),
[Directory.Build.props](../Directory.Build.props), [nuget.config](../nuget.config),
PowerShell 7 and Azure CLI. The retained prerequisite checker defines its exact
requirements; restoring Setup and validating a clean install remain M1 work.

The Purview package contract requires Windows x64, Microsoft-signed PowerShell
**7.6.5** and ExchangeOnlineManagement **3.10.1**. The package builder pins and
checks the selected runtime/module manifest; a newer installation does not
silently satisfy that contract. These constraints do not establish that the
current machine or a deleted executor is ready.

[config.schema.json](config.schema.json) and
[config.example.json](config.example.json) describe non-secret configuration:
tenant/subscription, project namespace, resource group, region, environment,
SQL tier, manager applications and selected capabilities. Use reviewed values
in the pinned subscription. Do not copy an old environment's configuration or
checkpoint into a new identity.

The retained new-configuration flow includes shared Azure AI Content Safety for
Prompt Shields. Per-agent usage remains optional. Purview prerequisites are
selected independently. Existing accepted configurations with Prompt Shields
disabled remain compatibility inputs, not evidence that a new configuration can
silently omit the service. The schema, terminal source and restored Setup must be
rechecked together before installation is presented as supported.

Registry provisioning remains a Development-only preview. Beta, cost/quota and
authority acknowledgements belong to the configuration/plan contract; they do
not grant unlimited scope or replace the current project authorization.
Passwords, tokens, clear Gateway keys, prompt/response text and certificate
material do not belong in configuration.

## Deployment responsibilities

The retained deployment assets describe:

- Container Apps for API, Admin UI and worker, with immutable ACR images;
- SQL, Service Bus, Blob storage, Key Vault, private networking and monitoring;
- Entra applications, app roles, managed identities, federation and a seed
  Agent Identity blueprint;
- database initialization through the missing migrator tool;
- shared Prompt Shields infrastructure and managed-identity access;
- optional Purview identities, authority prerequisites, certificate, dedicated
  administration queue and Windows executor/package-publisher infrastructure.

Bootstrap prepares capabilities. Gateway Settings owns tenant connection,
sensitive-information inventory, Know Your Data and DLP configuration, and runtime
verification. An installed capability is not an authored policy or a proven
allow/block result. The API synchronizes a source/ownership-bound
`BootstrapCapabilities` snapshot after deployment readback; those runtime facts
do not mark project milestones complete.

## Command reference

This table describes the retained launcher surface. It is not a claim that each
command has been executed or the complete workflow is usable after the reset.
Use `gateway.cmd` in place of `./gateway` on Windows.

| Command | Intended boundary |
|---|---|
| `setup` | Local setup UI; blocked by the absent Setup project. |
| `init` | Create non-secret configuration. |
| `doctor` | Check tools, configuration and provider readiness; can perform provider reads. |
| `plan` | Validate inputs, compile Bicep and run authenticated What-If. |
| `apply` / `up` | Execute a matching accepted plan, including live mutations. |
| `resume` | Reconcile and continue eligible work for the same accepted deployment. |
| `status` | Inspect local operational checkpoint/readiness state. |
| `verify` | Read back the live deployment boundary. |
| `open` | Open the recorded verified Admin UI endpoint. |
| `diagnose` | Write a sanitized local diagnostic bundle. |

Bounded database recovery and Admin UI upgrade commands also exist. They require
their eligible runtime state and retained dependencies; see
[operator workflows](../operations/README.md). Bootstrap has no general destroy,
Registry replay, retained-message or cleanup command.

## Plan, state and recovery

Plan binds exact source, configuration, target and What-If results. Apply rechecks
that binding before changing provider state. Fresh invocation admission and
continuation within an already authorized invocation have distinct rules.
A fingerprint is an integrity binding, not user authorization by itself.

Ignored `.bootstrap/` state supports safe reconciliation. It records non-secret
resource, identity, image and source identifiers. It is operational data, not a
parallel project acceptance record. Preserve it when investigating an eligible
real deployment.

Deployment identity comprises subscription, tenant, environment, location,
project name and resource group. Changing those fields changes the target.
Changing other configuration still invalidates the accepted configuration
binding; it does not authorize replaying completed mutations. Resume must retain
the accepted target/source and independently reconcile completed work.

Existing session authorization remains valid within its scope. The tools' exact
plan and operation guards still apply; do not invent repeat permission requests
for every read or bypass a required guard. Unknown outcomes require bounded
readback, not a repeated create. Never edit checkpoints to manufacture success.

Deleting an Azure resource group does not establish that its tenant objects or
retained service state were deleted. A deleted environment is a fresh-planning or
disaster-recovery case, not routine Resume. Namespace/ownership, regional SKU and
capacity checks require current provider evidence when that work begins. Do not
change SKUs, purge resources or relabel identities to force an old plan forward.

## After a verified installation

Use verified API/Admin endpoints to sign in, register an agent and securely
store its one-time key. Complete the delegated Registry handoff and inspect the
actual registration state. Configure installed protections in Settings; separate
policy readback, propagation and runtime evidence throughout.

See [the product flow](../README.md#main-user-journey),
[API contract](../docs/api/api-contract.md),
[Purview executor architecture](../docs/architecture/purview-windows-executor.md)
and [infrastructure assets](../infrastructure/README.md). Actual installation and
hosted acceptance belong only on the applicable milestone items.
