# A365 Gateway bootstrap

`bootstrap.ps1` is the supported first-deployment entry point for a clean Azure
subscription. It is an interactive, resumable state machine rather than a thin
wrapper around the existing update scripts.

## What it provisions

An `Apply` run performs these ordered phases:

1. verifies or installs PowerShell 7 (Windows launcher), Git, Azure CLI, Bicep,
   .NET 10, and ExchangeOnlineManagement when Purview is requested;
2. pins the exact Azure tenant and subscription and registers required providers;
3. creates the resource group, Log Analytics workspace, VNet, delegated Container
   Apps subnet, private-endpoint subnet, and VNet-integrated Container Apps
   environment;
4. creates or safely adopts the Gateway API Entra app, builds the real API, worker,
   and Admin UI images in the foundation ACR, and pins immutable digests;
5. deploys those real API/worker images inert so their managed identities exist;
6. issues at most one direct Microsoft Graph v1.0 create for one typed Agent ID
   seed blueprint; its exact display name is bound to deployment ownership and the
   accepted source, the authenticated administrator is its sole owner and sponsor,
   no blueprint credential is created, pre-existing same-name objects are never
   adopted, and `managerApplications` must exactly equal the independently reviewed
   IDs in configuration;
7. applies the exact eight worker Graph roles, the API blueprint-read role, the
   delegated Registry scopes/consent, and the API managed-identity OBO FIC;
8. creates SQL private DNS/endpoint, initializes an empty `GatewayDb` from the
   reviewed current EF model, and creates the API/worker database principals; the
   migration may temporarily enable SQL public access and creates one caller-IP-only
   firewall rule, then cleans up the exact targets and reads back both network
   changes;
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

## Golden path

Run from the repository root. On macOS or Linux:

```bash
./gateway setup
```

On Windows:

```powershell
gateway.cmd setup
```

This opens a temporary Fluent setup UI on an ephemeral `127.0.0.1` port. A
single-use local URL establishes the in-memory session, and the URL is immediately
removed from browser history. The UI discovers only safe Azure subscription
metadata from the current Azure CLI session, creates the ignored non-secret
`bootstrap/config.json`, runs Plan, presents the permission/preview/cost boundaries,
and requires a second explicit confirmation before mutation. All deployment work
still runs through `bootstrap/bootstrap.ps1`; the UI is not a second deployment
engine.

Prefer the terminal experience or cannot open a browser? Use:

```bash
./gateway doctor
./gateway up
```

`up` starts the configuration wizard when needed, compiles every deployment Bicep
template, runs subscription-scope ARM What-If, prints the imperative Entra/Graph/
Agent 365/SQL/Purview manifest, asks for confirmation, applies or resumes safe
checkpoints, verifies the result, and opens the hosted Admin UI when requested.

The base workstation requirements are PowerShell 7, Git, Azure CLI, and the .NET
10 SDK. `doctor` also verifies Bicep and the credential-free Microsoft Graph v1.0
blueprint provider, reports the current subscription/tenant match, and distinguishes failures
from authority, quota, regional SKU, licensing, and browser checks that remain
`NotChecked`. Docker is not required: ACR performs the image builds.

Prerequisite installation is itself a workstation mutation and is enabled by
default for supported commands. Depending on the platform and selected features,
bootstrap may install Git, Azure CLI, the .NET 10 SDK, or Bicep, and install
`ExchangeOnlineManagement` for the current user when Purview needs it. Pass
`--no-install` to `plan`, `up`, or `resume` when another workstation-management
process owns those changes; missing or mismatched tools will then fail with
remediation instead of being installed.

Before setup, independently verify the one-to-ten Microsoft first-party Agent 365
manager application IDs for the target tenant/provider. The wizard writes these to
`agent365.reviewedManagerApplicationIds`; the terminal plan displays the exact sorted
set and binds it into the accepted fingerprint. Replace the dummy GUID in
`config.example.json`. Blueprint or provider discovery is readback evidence only:
it must exactly match the reviewed set and never grants authority by itself. Follow
the review boundary in
[`docs/operations/entra-setup-runbook.md`](../docs/operations/entra-setup-runbook.md#43-agent-365-managerapplications-provider-prerequisite).

On macOS, Homebrew can install the base command-line tools:

```bash
brew install powershell git azure-cli
```

Install the .NET 10 SDK from Microsoft's platform installer if it is not already
available. On Windows, the lower-level `bootstrap/bootstrap.cmd` can install
PowerShell 7 with `winget`; the root launcher is the supported day-zero command
surface.

Azure, Agent ID/Graph, tenant consent, and optional Purview handoffs may open
official Microsoft authentication. The setup UI and bootstrap never collect or
render those credentials. A cached sign-in is required for non-interactive use.

### Command reference

| Command | Behavior |
|---|---|
| `gateway setup` | Start the local-only guided setup UI. |
| `gateway init` | Create or replace the reviewed non-secret configuration in the terminal. |
| `gateway doctor` | Check workstation, account, and explicitly unverified readiness items. |
| `gateway plan` | Compile source, show all mutation classes, and run ARM What-If; no cloud mutation. |
| `gateway up` | Configure if needed, plan, confirm, apply/resume, verify, and optionally open the portal. |
| `gateway apply` | Apply one still-current accepted plan. |
| `gateway resume` | Re-plan, confirm, and resume independently revalidated checkpoints. |
| `gateway status` | Show local checkpoint and layered readiness status without Azure calls. |
| `gateway verify` | Rerun authenticated, read-only deployment verification. |
| `gateway open` | Open only a recorded, verified HTTPS Admin UI endpoint. |
| `gateway diagnose` | Write a bounded, redacted support bundle containing safe identifiers only. |

There is intentionally no destroy command. Plan acceptance expires after 60 minutes
and is bound to the entire configuration, deployment-affecting source, and sorted
sanitized What-If prediction. A source/configuration change requires a new plan.
Acceptance materializes the reviewed deployment inputs in the ignored,
content-addressed `.bootstrap/accepted-source/<ownership>/<plan>/` tree. Apply and
Resume require the currently running checkout to match the accepted source exactly,
verify the snapshot hash, and reload mutation modules, templates, scripts, project
files, and ACR build inputs from that snapshot. If any durable step or output has
already been written, a different source generation cannot be planned or mixed
into that deployment state; restore the exact source or use a distinct deployment
identity.
The first live disposable execution must follow the
[`clean-subscription bootstrap proof`](../docs/operations/clean-subscription-bootstrap-proof.md)
runbook; local success alone is not deployment evidence.

For controlled automation, separate review from authorization. Preserve the JSON
Lines Plan result, extract the one top-level object whose `applyReady` is `true`,
and send its `planFingerprint` through the external approval system. This example
uses `jq` supplied by the CI image; `jq` is not a bootstrap prerequisite:

```bash
plan_artifact="$(mktemp)"
./gateway plan --json --non-interactive | tee "$plan_artifact"
plan_fingerprint="$(jq -ser '[.[] | select(.planFingerprint? and .applyReady == true)] | if length == 1 then .[0].planFingerprint else error("expected one apply-ready plan") end' "$plan_artifact")"

# The approval gate reviews the full artifact and returns exactly this fingerprint.
: "${APPROVED_PLAN_FINGERPRINT:?external approval did not supply a plan fingerprint}"
test "$APPROVED_PLAN_FINGERPRINT" = "$plan_fingerprint"
./gateway up --json --non-interactive --yes \
  --expected-plan-fingerprint "$APPROVED_PLAN_FINGERPRINT"
```

For an interrupted run, carry a newly reviewed fingerprint into Resume:

```bash
./gateway resume --json --non-interactive --yes \
  --expected-plan-fingerprint "$APPROVED_PLAN_FINGERPRINT"
```

On Windows, use the same long options with `gateway.cmd`. `--yes` alone authorizes
the plan freshly recomputed inside that `up` or `resume`; it does **not** prove that
a previously emitted plan was reviewed. Only the expected fingerprint binds
external approval to the full configuration, deployment source, descriptor, and
sorted sanitized ARM What-If prediction. Never put secrets on the command line or
in configuration.

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
  wants the deployed Gateway adapter enabled after that read-back. The separate
  protection-profile automation switch `policyProvisioningEnabled` is accepted only
  when this adapter-activation switch is also true, so Plan cannot advertise a
  worker feature that Apply would silently leave disabled.

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

- `Init` creates reviewed non-secret configuration.
- `Doctor` reports workstation/account readiness and truthful `NotChecked` items.
- `Plan` validates configuration and deployment source, runs ARM What-If, and may
  record a short-lived exact-plan acceptance; it does not mutate cloud resources.
- `Apply` consumes an accepted, current plan and starts or continues a deployment.
- `Resume` generates a fresh plan, asks for authorization, and continues only
  independently revalidated step evidence.
- `Status` reads local safe state without making Azure calls.
- `Verify` performs final authenticated read-only checks from existing state.
- `Open` opens only the recorded verified HTTPS Admin UI endpoint.
- `Diagnose` writes a redacted local support bundle.
- `Up` composes Init, Plan, explicit approval, Apply/Resume, and Verify.

Safe state is stored under `.bootstrap/state/` and evidence under
`.bootstrap/evidence/`; both are ignored by Git. Completed steps are not blindly
replayed or blindly trusted: each reusable mutation checkpoint must pass its own
read-only validator, and a missing or ambiguous validator fails closed while
preserving evidence. If a step failed, fix the reported cause and use `Resume`. A
per-deployment lock prevents concurrent runs. Never edit the state to claim a step
completed.
The reviewed plan makes the seed-blueprint disposition explicit and binds it into
the plan fingerprint. A fresh state may authorize at most one Graph POST; a
`Running` or `Failed` blueprint step is GET-only reconciliation, and a `Completed`
step is read-only revalidation. An exact-name object found during recovery must
also match the persisted ownership/source boundary, administrator owner/sponsor,
reviewed manager applications, credential-free application surface, and the exact
pristine-or-Gateway-activated principal/FIC authority surface. Resume never turns a
prior unknown create outcome into a second POST or name-only adoption.
Prerequisite and exact tenant/subscription checks run on every Apply/Resume, and
final verification is never accepted from stale state. If a previously completed
resource group was deleted, bootstrap preserves its state and fails before any
replay. Tenant-scoped Entra/Agent ID objects can survive while Key Vault credential
metadata does not, so rebuilding that identity requires a separately reviewed
disaster-recovery procedure or a new isolated deployment identity.
The verified subscription ID is also appended to every supported Azure CLI,
deployment, and Graph `az rest` call, so a later default-subscription change cannot
redirect the operation; tenant and subscription readback still fail closed.

Each new deployment state contains a generated, unguessable
`deploymentOwnershipId`. The two bootstrap-managed Entra applications must carry
exactly the corresponding `A365GatewayBootstrap` and
`A365GatewayOwnership:<id>` tags and exactly the pinned bootstrap operator as
owner. Bootstrap may reuse an application only when that state-owned identity and
its reviewed contract read back exactly. A same-name application without the exact
marker, an ownership mismatch, or ambiguous results are treated as a collision and
fail closed; bootstrap never adopts them by display name alone.

The same ownership ID and accepted source fingerprint are emitted by the ARM
deployments and tagged on the bootstrap-created runtime resources. Image evidence
records the source fingerprint and digest-pinned API, worker, and Admin UI images.
Checkpoint reuse requires exact deployment parameters/outputs, resource tags,
managed-identity IDs, and deployed image references; a matching resource name is
not sufficient.

Database initialization is also explicitly recoverable. For the bounded migration
session, bootstrap may temporarily change the SQL server from public access
`Disabled` to `Enabled` and creates exactly one deterministic firewall rule whose
start/end address both equal the caller IPv4 shown by Plan and bound into the plan
fingerprint/state. Plan accepts that address only when bounded HTTPS reads from
ipify and AWS Check IP return the same canonical IPv4. Its `finally` cleanup deletes
that exact rule and reads back absence, restores `Disabled`, and reads back the
restored state. Before mutation it writes the safe ignored record
`.bootstrap/evidence/<resource-group>/database/GatewayDb-network-recovery.json`.
The record contains identifiers and cleanup intent, not credentials. It is removed
only after both cleanup checks succeed; otherwise bootstrap fails closed, preserves
the record, and `resume` reconciles that exact operation before continuing.

The state may contain tenant, subscription, resource, application, principal,
blueprint, image-digest, endpoint, and policy identifiers. It never contains SQL
passwords, app secret values, access tokens, Gateway keys, prompts, or responses.
The bootstrap does not read `.secrets`. Both `.bootstrap/` and local
`bootstrap/config.json` are excluded from Git and the remote ACR build context.

## Administrator and eligibility matrix

| Boundary | Minimum reviewed authority or requirement | When needed |
|---|---|---|
| Azure resources | Contributor at subscription scope | Every Apply |
| Azure role assignments | Role Based Access Control Administrator, User Access Administrator, or Owner at the required scope | Every Apply |
| Entra applications/service principals | Tenant authority to create the project-scoped applications and service principals | Every Apply |
| Delegated Graph consent | Privileged Role Administrator or another tenant role authorized to grant the exact reviewed scopes | Every Apply |
| Agent ID | Agent ID Developer or a role containing the required blueprint/identity operations | Every Apply |
| Agent 365 service | Eligible tenant, licensing, and current service availability | Blueprint setup and real canary |
| Purview | Eligible licensing plus the documented collection/DLP authoring roles | Only when Purview is enabled |
| Prompt Shields | Supported Azure AI Content Safety region, SKU, and quota | Only when Prompt Shields is enabled |

`doctor` can prove tool versions, cached account identity, visible subscriptions,
selected provider state, and some role assignments when the caller may read them.
It cannot prove every quota, regional data-plane SKU, Conditional Access handoff,
Agent 365 license, Purview propagation/verdict, signed-in Admin UI route, first
Active agent, or data-plane canary. Those remain visibly `NotChecked` until their
own later evidence exists.

The guided profiles are defaults, not authorization shortcuts:

- **Quick development** selects `dev`; Registry preview, Prompt Shields, Purview,
  and paid Prompt Shields S0 remain separate opt-ins.
- **Staging foundation** keeps direct Registry creation closed and makes no
  production-readiness claim.
- **Production-safe foundation** deploys the supported foundation while keeping the
  beta Registry boundary closed; production rollout still requires the separate
  readiness reviews.

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
versionless secret in the Gateway shared Key Vault. It also requires
`purview.activateGatewayAdapterAfterPolicyReadback=true`. Supply only the verified
organization domain, application/client ID, and secret URI in `config.json`.

When enabled, bootstrap grants the worker **Key Vault Secrets User** only at the
exact configured certificate-secret resource, not at the shared-vault scope. The
Admin UI user-assigned identity receives the same role only on its exact Entra
client-secret resource, and the API receives no shared-vault role. Final Verify
reads these exact assignments and the worker's Purview settings back; when Purview
provisioning is disabled, its certificate-read assignment must be absent.
Certificate values and passwords never belong in configuration, bootstrap state,
or documentation. Bootstrap deliberately does not create or privilege the
tenant-wide Microsoft 365 automation application. The stricter runtime Purview
scope/ID/action readback, temporary-certificate cleanup proof, and final
revalidation before `Active` are local unreleased source with no live proof. Follow
the exact prerequisites and read-back checks in
[`docs/operations/purview-setup-runbook.md`](../docs/operations/purview-setup-runbook.md).

## Files

- `../gateway` and `../gateway.cmd` — supported cross-platform command surface.
- `../tools/Gateway.Setup` — ephemeral loopback-only Fluent setup UI; it delegates
  to the canonical PowerShell engine and stores only in-memory session state.
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
runbooks. These are source-reviewed behaviors; a disposable clean-subscription
Apply and canary still must be captured before this bootstrap path is called
live-proven.

## Official capability references

- [Install PowerShell on macOS](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-macos)
- [Install Azure CLI on macOS](https://learn.microsoft.com/cli/azure/install-azure-cli-macos)
- [Install .NET on macOS](https://learn.microsoft.com/dotnet/core/install/macos)
- [Subscription-scope Bicep deployments](https://learn.microsoft.com/azure/azure-resource-manager/bicep/deploy-to-subscription)
- [Create an Agent Identity blueprint](https://learn.microsoft.com/graph/api/agentidentityblueprint-post?view=graph-rest-1.0)
- [List Agent Identity blueprint owners](https://learn.microsoft.com/graph/api/agentidentityblueprint-list-owners?view=graph-rest-1.0)
- [List Agent Identity blueprint sponsors](https://learn.microsoft.com/graph/api/agentidentityblueprint-list-sponsors?view=graph-rest-1.0)
- [Agent 365 registration setup](https://learn.microsoft.com/microsoft-agent-365/developer/registration)
- [Configure Purview for custom AI apps](https://learn.microsoft.com/purview/developer/configurepurview)
- [Prompt Shields REST API](https://learn.microsoft.com/rest/api/contentsafety/text-operations/shield-prompt?view=rest-contentsafety-2024-09-01)
- [Cognitive Services User role](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/ai-machine-learning)
- [Microsoft identity consent model](https://learn.microsoft.com/entra/identity-platform/permissions-consent-overview)
- [Agent Registration create API (beta limitation)](https://learn.microsoft.com/microsoft-365/copilot/extensibility/api/admin-settings/agent-registration/agentregistration-create)
