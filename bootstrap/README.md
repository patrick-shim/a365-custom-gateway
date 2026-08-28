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
11. deploys the current runtime and Admin UI, sets exact redirect URIs, disables
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
entry point can then install the remaining supported prerequisites. On Linux or
macOS, install PowerShell 7, Azure CLI, and .NET 10 using Microsoft's platform
instructions, then run `pwsh ./bootstrap/bootstrap.ps1 ...`.

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

## Agent 365 and Purview boundaries

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

## Files

- `bootstrap.ps1` — orchestration and state transitions.
- `bootstrap.cmd` — Windows PowerShell-7 launcher.
- `config.example.json` and `config.schema.json` — non-secret configuration example
  and machine-readable schema.
- `modules/` — prerequisite, Azure, Entra, Agent 365, SQL, Purview, and verification
  functions.
- `infra/` — subscription/foundation and SQL-private-endpoint Bicep.

The bootstrap composes the reviewed templates and scripts under `deploy/` and
`tools/`; it does not replace the upgrade, incident, or canary runbooks.

## Official capability references

- [Subscription-scope Bicep deployments](https://learn.microsoft.com/azure/azure-resource-manager/bicep/deploy-to-subscription)
- [Install the Agent 365 CLI](https://learn.microsoft.com/microsoft-agent-365/developer/agent-365-cli)
- [Agent 365 CLI setup reference](https://learn.microsoft.com/microsoft-agent-365/developer/reference/cli/setup)
- [Agent 365 registration setup](https://learn.microsoft.com/microsoft-agent-365/developer/registration)
- [Configure Purview for custom AI apps](https://learn.microsoft.com/purview/developer/configurepurview)
- [Microsoft identity consent model](https://learn.microsoft.com/entra/identity-platform/permissions-consent-overview)
- [Agent Registration create API (beta limitation)](https://learn.microsoft.com/microsoft-365/copilot/extensibility/api/admin-settings/agent-registration/agentregistration-create)
