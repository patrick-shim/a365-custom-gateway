# A365 Gateway bootstrap

`bootstrap.ps1` is the supported first-deployment entry point for a clean Azure
subscription. It is an interactive, resumable state machine rather than a thin
wrapper around the existing update scripts.

## What it provisions

An `Apply` run performs these ordered phases:

1. verifies or installs PowerShell 7 (Windows launcher), Git, Azure CLI, Bicep,
   .NET 10, the Agent 365 CLI, and ExchangeOnlineManagement when Purview is
   requested;
2. pins the exact Azure tenant and subscription and registers required providers;
3. creates the resource group, Log Analytics workspace, VNet, delegated Container
   Apps subnet, private-endpoint subnet, and VNet-integrated Container Apps
   environment;
4. creates or safely adopts the Gateway API Entra app, builds the real API, worker,
   and Admin UI images in the foundation ACR, and pins immutable digests;
5. deploys those real API/worker images inert so their managed identities exist;
6. creates or adopts one typed Agent ID seed blueprint through the official Agent
   365 CLI and reads its tenant/provider `managerApplications` from Graph;
7. applies the exact eight worker Graph roles, the API blueprint-read role, the
   delegated Registry scopes/consent, and the API managed-identity OBO FIC;
8. creates SQL private DNS/endpoint, initializes an empty `GatewayDb` from the
   reviewed current EF model, and creates the API/worker database principals;
9. creates the Admin UI Entra app and transfers its one-time secret directly to
    Key Vault without rendering or persisting the value;
10. optionally creates blueprint-scoped Purview collection and inline DLP policy
    objects, using `Application` as the enforcement plane;
11. optionally creates an Azure AI Content Safety account for Prompt Shields and
    grants the API managed identity only the built-in Cognitive Services User role;
12. deploys the current runtime and Admin UI, sets exact redirect URIs, disables
    SQL and Key Vault public access, and performs health/private-network/identity/
    permission/provisioning read-back checks.

The script has no destroy mode. Resource deletion, purge, retained-message access,
historical replay, and SQL finalization remain separate reviewed operations.

## Quick start on Windows

1. Copy `config.example.json` to `config.json`.
2. Replace every placeholder. Choose a distinctive 2-8 character `projectName`;
   it participates in globally scoped Key Vault, SQL, and Service Bus names. Do not
   put secrets in this file.
3. Open Command Prompt or PowerShell as the tenant/subscription administrator.
4. Plan, then apply:

```powershell
bootstrap\bootstrap.cmd -Mode Plan -Config bootstrap\config.json
bootstrap\bootstrap.cmd -Mode Apply -Config bootstrap\config.json -OpenBrowser
```

`bootstrap.cmd` installs PowerShell 7 with `winget` when needed. The PowerShell
entry point can then install the remaining supported prerequisites.

## Quick start on macOS

The bootstrap is cross-platform PowerShell, but `bootstrap.cmd` and automatic
installation of Git, Azure CLI, and .NET are Windows-only. On macOS, install the
base toolchain first. The commands below work on both Apple silicon and Intel Macs;
for .NET, select the installer matching the Mac's processor architecture.

1. Install [Homebrew](https://brew.sh/) if it is not already available, then install
   PowerShell 7, Git, and Azure CLI:

```bash
brew update
brew install powershell git azure-cli
```

   A Microsoft-signed PowerShell package is also available from the official
   [PowerShell macOS installation guide](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-macos).

2. Install the **.NET 10 SDK**, not only the runtime, from the official
   [.NET macOS installation guide](https://learn.microsoft.com/dotnet/core/install/macos).
   Choose Arm64 for Apple silicon or x64 for an Intel Mac.

3. Open a new Terminal and verify the required commands. The `dotnet` version must
   begin with `10.`:

```bash
pwsh --version
git --version
az version
dotnet --version
```

4. From the repository root, create the ignored local configuration and edit every
   placeholder. Do not put passwords, tokens, certificates, Gateway keys, or other
   secrets in this file:

```bash
cp bootstrap/config.example.json bootstrap/config.json
nano bootstrap/config.json
```

5. Run an explicit non-mutating plan, then the resumable apply:

```bash
pwsh ./bootstrap/bootstrap.ps1 -Mode Plan -Config ./bootstrap/config.json
pwsh ./bootstrap/bootstrap.ps1 -Mode Apply -Config ./bootstrap/config.json -OpenBrowser
```

   If the shell is already in the `bootstrap` directory, use
   `pwsh ./bootstrap.ps1 -Mode Plan -Config ./config.json` and the corresponding
   `Apply` command. Running `pwsh bootstrap.ps1` alone implicitly selects `Plan`
   and `./config.json`, but the explicit form is recommended so the intended mode
   and file are always visible.

The macOS run installs/verifies Bicep through Azure CLI and can install the Agent
365 CLI plus `ExchangeOnlineManagement` for the current user. If `a365` is installed
but a later Terminal cannot find it, add the .NET global-tools directory to zsh and
open a new Terminal:

```bash
echo 'export PATH="$PATH:$HOME/.dotnet/tools"' >> ~/.zprofile
source ~/.zprofile
a365 --version
```

The first `Apply` is intentionally interactive. Azure, Agent 365, tenant consent,
and Purview may open browser/device authentication. Do not add `-NonInteractive`
until all interactive prerequisites already exist. `-OpenBrowser` opens the Admin
UI after successful verification; if macOS does not open it automatically, use the
Admin UI URL printed at the end.

### Fixing the Purview sensitive-information-type error

This error is a configuration guard and is independent of macOS:

```text
purview.sensitiveInformationType is required when Purview is enabled
```

It occurs while `config.json` is loaded, before `Plan` or `Apply` changes Azure. Use
one of these two valid configurations:

- To bootstrap without Purview initially, keep the complete `purview` object from
  `config.example.json` and set:

```json
{
  "enabled": false,
  "activateGatewayAdapterAfterPolicyReadback": false,
  "collectionPolicyName": "A365 Gateway AI collection",
  "dlpPolicyName": "A365 Gateway inline DLP",
  "dlpRuleName": "A365 Gateway inline DLP rule",
  "sensitiveInformationType": "",
  "policyProvisioningEnabled": false,
  "policyProvisioningOrganization": "",
  "policyProvisioningApplicationId": "",
  "policyProvisioningCertificateSecretUri": ""
}
```

- To include Purview, set `enabled` to `true` and replace the empty
  `sensitiveInformationType` with the exact tenant-approved Purview sensitive
  information type name. Do not use a guessed name. Keep
  `activateGatewayAdapterAfterPolicyReadback` false if this run should only create
  and read back policy configuration; set it true only when the operator explicitly
  wants the deployed Gateway adapter enabled after that read-back.

After correcting `bootstrap/config.json`, rerun `Plan`, then `Apply`. If a later
`Apply` step fails, fix that reported cause and use `-Mode Resume` with the same
configuration instead of deleting `.bootstrap` state or starting a second run.

The signed-in account needs Azure subscription Owner (or Contributor plus User
Access Administrator) rights, permission to create Entra applications/service
principals and grant admin consent, Agent ID
Developer (or a role that includes the required Agent ID operations), and the
Purview roles required to author collection/DLP policies when that option is on.
Some consent and Purview connections intentionally display Microsoft interactive
authentication. `-NonInteractive` fails instead of bypassing those boundaries.

## Modes and recovery

- `Plan` validates configuration and source templates without changing Azure.
- `Apply` starts or continues a deployment.
- `Resume` is an explicit alias for continuing from recorded step evidence.
- `Verify` performs the final read-only checks from an existing state file.

Safe state is stored under `.bootstrap/state/` and evidence under
`.bootstrap/evidence/`; both are ignored by Git. Completed steps are not blindly
replayed. If a step failed, fix the reported cause and use `Resume`. A per-deployment
lock prevents concurrent runs. Never edit the state to claim a step completed.
Prerequisite and exact tenant/subscription checks run on every Apply/Resume, and
final verification is never accepted from stale state. If the recorded resource
group was deleted, the bootstrap detects that after authentication, clears only
its dependent safe state, and rebuilds through the same idempotent workflow.

The state may contain tenant, subscription, resource, application, principal,
blueprint, image-digest, endpoint, and policy identifiers. It never contains SQL
passwords, app secret values, access tokens, Gateway keys, prompts, or responses.
The bootstrap does not read `.secrets`. Both `.bootstrap/` and local
`bootstrap/config.json` are excluded from Git and the remote ACR build context.

## Agent 365, Prompt Shields, and Purview boundaries

`promptShield.enabled` provisions Azure AI Content Safety in the Gateway region,
disables local-key authentication, injects only its endpoint into the API, and uses
the API Container App managed identity for `https://cognitiveservices.azure.com/.default`.
The runtime calls the GA `2024-09-01` Prompt Shield API. A provider failure is a
closed decision for registrations that enabled the control. Provisioning the
resource does not enable Prompt Shields on every registration; the system default
and per-registration checkbox remain explicit controls.
Final bootstrap verification reads the exact Content Safety resource back, proves
local authentication is disabled, and proves the Gateway API managed identity has
the Cognitive Services User role at that resource scope.

The current direct Agent Registration create API is beta and explicitly unsupported
for production. Therefore full automatic Gateway registration is enabled only when
`environment` is `dev` and `agent365.allowDevelopmentRegistryPreview` is `true`.
Staging and production deployments remain fail-closed at that boundary; the script
does not relabel preview behavior as production-ready.

Purview setup requires an explicit tenant-approved sensitive-information type. The
bootstrap never invents a classifier or overwrites an incompatible existing policy.
Policy creation/read-back proves configuration, not propagation or a block verdict.
The Gateway adapter remains off unless
`purview.activateGatewayAdapterAfterPolicyReadback` is also explicitly true; that
switch is an operator acknowledgement, not synthetic-canary evidence.
After the first real registration, use the documented bounded data-plane canary and
confirm both benign and synthetic-sensitive behavior before treating new-tenant DLP
as live proof.

The optional Admin UI protection-profile workflow is configured separately with
`purview.policyProvisioningEnabled`. Keep it `false` unless a certificate-authenticated
application already has `Exchange.ManageAsApp` plus the required Security &
Compliance PowerShell RBAC, and its base64 PKCS#12 certificate is stored as a
versionless secret in the Gateway shared Key Vault. Supply only the verified
organization domain, application/client ID, and secret URI in `config.json`.

When enabled, bootstrap grants the worker only **Key Vault Secrets User** on the
shared vault. Certificate values and passwords never belong in configuration,
bootstrap state, or documentation. Bootstrap deliberately does not create or
privilege the tenant-wide Microsoft 365 automation application. Follow the exact
prerequisites and read-back checks in
[`docs/operations/purview-setup-runbook.md`](../docs/operations/purview-setup-runbook.md).

## Files

- `bootstrap.ps1` — orchestration and state transitions.
- `bootstrap.cmd` — Windows PowerShell-7 launcher.
- `config.example.json` and `config.schema.json` — non-secret configuration example
  and machine-readable schema.
- `modules/` — prerequisite, Azure, Entra, Agent 365, SQL, Purview, and verification
  functions.
- `infra/` — subscription/foundation and SQL-private-endpoint Bicep.

The bootstrap composes declarative assets under [`../infrastructure/`](../infrastructure/README.md),
operational scripts under [`../operations/`](../operations/README.md), and shared
utilities under `../tools/`. It does not replace the upgrade, incident, or canary
runbooks.

## Official capability references

- [Install PowerShell on macOS](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-macos)
- [Install Azure CLI on macOS](https://learn.microsoft.com/cli/azure/install-azure-cli-macos)
- [Install .NET on macOS](https://learn.microsoft.com/dotnet/core/install/macos)
- [Subscription-scope Bicep deployments](https://learn.microsoft.com/azure/azure-resource-manager/bicep/deploy-to-subscription)
- [Install the Agent 365 CLI](https://learn.microsoft.com/microsoft-agent-365/developer/agent-365-cli)
- [Agent 365 CLI setup reference](https://learn.microsoft.com/microsoft-agent-365/developer/reference/cli/setup)
- [Agent 365 registration setup](https://learn.microsoft.com/microsoft-agent-365/developer/registration)
- [Configure Purview for custom AI apps](https://learn.microsoft.com/purview/developer/configurepurview)
- [Prompt Shields REST API](https://learn.microsoft.com/rest/api/contentsafety/text-operations/shield-prompt?view=rest-contentsafety-2024-09-01)
- [Cognitive Services User role](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/ai-machine-learning)
- [Microsoft identity consent model](https://learn.microsoft.com/entra/identity-platform/permissions-consent-overview)
- [Agent Registration create API (beta limitation)](https://learn.microsoft.com/microsoft-365/copilot/extensibility/api/admin-settings/agent-registration/agentregistration-create)
