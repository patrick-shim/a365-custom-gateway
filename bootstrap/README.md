# A365 Gateway bootstrap

The bootstrap is the supported deployment system for a new A365 Custom Gateway. It
owns the path from non-secret configuration through Azure What-If, explicit plan
acceptance, Azure and tenant provisioning, database initialization, immutable image
deployment, and final verification.

Run it through `./gateway` on macOS/Linux or `.\gateway.cmd` on Windows. The launcher
delegates to `bootstrap/bootstrap.ps1`; lower-level scripts are not alternate
installers.

## What it deploys

The bootstrap creates one named resource group containing the Gateway's Azure
foundation and workloads, then creates the required tenant-side identity objects.
The deployed system includes:

- Azure Container Apps for the Admin UI, API, and provisioning worker;
- Azure Container Registry and immutable workload images;
- Azure SQL, Service Bus, Blob storage, Key Vault, private networking, logs, alerts,
  and Application Insights;
- Entra applications, app roles, managed identities, federated credentials, and
  the seed Agent ID blueprint;
- the ordered Gateway database schema; and
- optional Azure AI Content Safety and optional Purview policy-authoring
  prerequisites. Purview runtime enforcement is enabled only after the separate
  post-bootstrap verification in the Purview runbook.

```mermaid
flowchart TD
    config[Reviewed non-secret configuration] --> whatif[Azure What-If]
    whatif --> approval[Explicit plan acceptance]
    approval --> foundation[Azure foundation]
    foundation --> identity[Entra and Agent ID setup]
    identity --> database[Empty database initialization]
    database --> images[Immutable workload images]
    images --> runtime[Admin UI, API, worker]
    runtime --> verify[Read-only verification]
    verify --> endpoints[Verified Admin UI and API endpoints]
```

## Prerequisites

- Git
- .NET 10 SDK
- PowerShell 7 (`pwsh`)
- Azure CLI 2.76 or later (`az`)
- an enabled Azure subscription in the target Microsoft Entra tenant
- an Azure account with Subscription Owner, or Contributor plus permission to make
  the role assignments shown by Plan
- an administrator able to approve the Entra and Agent ID changes
- Agent 365 tenant eligibility and licensing
- for optional Purview policy authoring, the same work account that Azure CLI and
  Microsoft Graph resolve for the selected tenant, with Graph `userType=Member` and
  the required Security & Compliance PowerShell roles; a `Guest` result or
  mismatched Security & Compliance session is rejected. Gateway-managed profile
  automation additionally requires its approved application and Key Vault
  certificate path; run this optional flow from Windows because Microsoft currently
  documents `Connect-IPPSSession` as unavailable in PowerShell 7 on macOS and Linux

The installer uses official Microsoft sign-in surfaces. It never asks you to paste
an Azure password, access token, client secret, certificate, or Gateway key into its
configuration.

## Guided deployment

From the repository root:

```bash
az login
./gateway setup
```

On Windows PowerShell or Command Prompt, run:

```powershell
az login
.\gateway.cmd setup
```

Setup listens only on an ephemeral `127.0.0.1` port. It lets you select a
subscription visible to Azure CLI, loads that subscription's physical Azure
locations into a dropdown, discovers compatible Agent 365 manager applications,
and lets you choose optional features. The core installer remains supported on
Windows, macOS, and Linux. The optional Purview inventory and policy-authoring path
is Windows-only: Microsoft currently documents `Connect-IPPSSession` and Security &
Compliance PowerShell as unavailable in PowerShell 7 on
[macOS and Linux](https://learn.microsoft.com/powershell/exchange/exchange-online-powershell-v2?view=exchange-ps#supported-operating-systems-for-the-exchange-online-powershell-module).
On macOS or Linux, leave Purview disabled or run Purview selection and bootstrap
from Windows; an attempted terminal selection stops before Microsoft Graph,
Security & Compliance, or sensitive-information-type inventory calls. On Windows,
if Purview is selected, click **Load tenant types**. That explicit action opens
Microsoft's Security & Compliance PowerShell sign-in for the same work account that
Azure CLI and Microsoft Graph resolved in the selected tenant. Graph must report
`userType=Member`; a `Guest`
result or mismatched Security & Compliance session is rejected. Use **Retry tenant
type discovery** if sign-in or inventory loading fails.
The native dropdown has no implicit selection and shows every returned exact
Unicode name with its GUID and publisher. Choose the type your organization
approves. Setup stores both its GUID and exact current name; there is no static
catalog or free-text classifier fallback. Region labels are paired with their
canonical Azure values—for example,
`Korea Central · koreacentral`—and the configuration stores `koreacentral`. Setup
does not accept a free-text region or silently choose one. Only after every required
selection has current proof does Setup atomically write `bootstrap/config.json`.
It then runs Plan, displays the exact deployment boundaries, and requires a second
explicit confirmation before Apply. If an accepted deployment later stops, Setup
offers a read-only resume review first. That review runs its own process, installs
nothing, changes no Azure, Entra, Agent 365, SQL, or policy resource, and returns
one accepted plan fingerprint plus a single-use authorization. Only then does Setup
offer a separate Resume confirmation. This source path is implemented and covered by
tests; it has not yet been exercised in a hosted browser against preserved stopped
state, so use the terminal Resume path for recovery evidence.

Keep the terminal open. Deployment may hand control to official Microsoft browser
windows for refreshed Azure, Entra, Agent ID, or Purview authentication. Setup
closes after completion and does not become part of the hosted Gateway.

## Terminal deployment

The same deployment can be run without the setup UI:

```bash
./gateway doctor
./gateway init
./gateway plan
./gateway apply --open
```

Windows uses the same command names through the root launcher:

```powershell
.\gateway.cmd doctor
.\gateway.cmd init
.\gateway.cmd plan
.\gateway.cmd apply --open
```

`init` interactively creates `bootstrap/config.json`. You can instead copy
`bootstrap/config.example.json`, replace every placeholder, and pass a different
file with `--config PATH`.

### Command reference

| Command | Behavior |
|---|---|
| `setup` | Start the temporary loopback-only setup UI. |
| `up` | Create configuration if needed, Plan, confirm, Apply/Resume, and Verify. |
| `init` | Create a reviewed non-secret configuration interactively. |
| `doctor` | Check tools, configuration, Azure CLI account, and subscription readiness. |
| `plan` | Validate inputs, compile Bicep, and run authenticated Azure What-If. |
| `apply` | Apply an accepted current plan and run final verification. |
| `resume` | Reconcile and continue an interrupted accepted plan from the terminal. |
| `status` | Show local checkpoint/readiness state without Azure calls. |
| `verify` | Rerun read-only deployment verification. |
| `open` | Open the recorded verified Admin UI HTTPS endpoint. |
| `diagnose` | Write a sanitized diagnostic bundle. |

Narrow recovery and upgrade commands also appear in `./gateway --help`. Use them
only when the matching failure boundary or runbook explicitly calls for them; they
are not alternate installation paths.

Common options include `--config PATH`, `--json`, `--non-interactive`, `--yes`,
`--expected-plan-fingerprint SHA256`, `--open`, and `--no-install`. Run
`./gateway --help` for the exact current surface.

## Configuration

`bootstrap/config.json` is non-secret and ignored by Git. The JSON schema is
`bootstrap/config.schema.json`; the example is `bootstrap/config.example.json`.
Configuration selects:

- the exact subscription and tenant;
- environment, canonical Azure location, project name, resource group, and alert
  email;
- SQL service tier;
- seed blueprint name and reviewed manager-application allowlist;
- development-only Registry preview enablement; and
- optional Prompt Shields and Purview settings.

When Purview is enabled, configuration binds `sensitiveInformationTypeId` to the
exact `sensitiveInformationType` name returned for that GUID. Setup and terminal
`init` obtain this pair from the live tenant inventory. They store the GUID in
canonical lowercase `D` form and preserve the Name exactly without trimming,
case-folding, translation, or Unicode normalization.

The deployment profile matters. A development configuration may explicitly enable
the preview Registry path so a registration can reach Gateway-reported `Active`.
Staging and production configurations keep Registry creation closed.

Do not put credentials, tokens, Gateway keys, prompt/response content, or
certificate material in configuration. Purview automation records only an
application ID, organization domain, and Key Vault secret URI; the certificate is
loaded through its approved non-echoing runtime path.

## Plan, Apply, Resume, Verify

Bootstrap is a resumable state machine:

1. `plan` validates configuration and source, compiles Bicep, runs authenticated
   subscription-scope What-If, and shows imperative tenant operations. Before
   What-If, it proves the configured SQL edition, service objective, 2 GiB size, and
   LRS storage path are available in the selected Azure region.
2. Explicit acceptance binds the exact plan fingerprint, configuration, source,
   target, and What-If prediction for a limited time.
3. `apply` revalidates that binding before mutation and writes safe checkpoint
   evidence after each verified action.
4. `resume` reconciles completed checkpoints and continues only work that remains
   safe for the same accepted plan.
5. `verify` reads back the deployed boundary without creating or updating it.

Terminal Resume is supported. The engine runs a read-only checkpoint review and then
requires both the accepted-Plan fingerprint and the resulting Resume authorization
fingerprint in a separately authorized process. The local Setup UI now performs that
same two-process exchange after Setup restarts: it starts one read-only review
without `-Yes`, holds the returned authorization only in memory for a single
confirmation, and discards it on restart, a changed checkpoint, another command, a
failed review, or cancellation. That browser path has not yet been validated against
preserved stopped state, so do not use a restarted browser session as recovery
evidence until it has.

State and sanitized evidence live under ignored `.bootstrap/`. They may contain
tenant, subscription, resource, application, principal, image-digest, and
fingerprint identifiers. They never contain credentials, access tokens, clear
Gateway keys, prompts, responses, or provider bodies.

For automation, create and review a fresh JSON plan, then require the exact emitted
fingerprint at the mutation gate:

```bash
./gateway plan --config bootstrap/config.json --json --non-interactive
./gateway up --config bootstrap/config.json --json --non-interactive --yes \
  --expected-plan-fingerprint sha256:REVIEWED_FINGERPRINT
```

The second command stops before mutation if source, configuration, target, or
What-If output changed.

The region dropdown is the selected subscription's Azure Resource Manager inventory
of physical locations. Visibility in that inventory is not proof that every service
or SKU is available there. `doctor`, `plan`, and the pre-mutation Apply revalidation
use the Azure SQL regional capabilities endpoint for the exact configured SQL path;
an unavailable or unverified path stops safely and asks you to choose another
dropdown region.

## Optional runtime protections

Prompt Shields and Purview are optional and independent.

### Prompt Shields

Set `promptShield.enabled` to `true` to deploy Azure AI Content Safety and authorize
the Gateway API managed identity. The account has local authentication disabled;
the bootstrap does not provision or store an account key. Registrations still opt
in individually in the Admin UI.

### Microsoft Purview

Set `purview.enabled` to `true` only when you want bootstrap to prepare the optional
policy-authoring path. This optional path runs only on Windows; core bootstrap is
still supported on macOS and Linux when Purview is disabled. Guided Setup and
terminal `init` connect through
`Connect-IPPSSession`, enumerate the selected tenant with
`Get-DlpSensitiveInformationType`, and require an explicit no-default selection.
The selected GUID is re-resolved and must still map to the exact stored name before
configuration publication, policy mutation, and typed readback; a removed, renamed,
duplicated, unauthorized, malformed, or oversized inventory stops safely. If
`policyProvisioningEnabled` is true, the Gateway-managed profile path additionally
uses its approved certificate authority. Bootstrap always deploys the Gateway with
`Purview__Enabled=false`; enabling runtime enforcement requires the separate
token-role and bounded data-plane checks in the Purview runbook.

Purview uses two distinct Application-plane locations:

| Purpose | Location | Source | Type |
|---|---|---|---|
| Know Your Data collection | Fixed tenant-wide enterprise-AI-apps location `ee1680d0-702f-4090-b26c-c49091e86531` | Entra | `Group` |
| DLP policy/rule | Selected reusable blueprint application/client ID | Entra | `Individual` |

The KYD collection is not blueprint-scoped, and the DLP policy is not Group-scoped.
Exact readback proves configuration, not policy propagation or a data-plane
allow/block verdict. Follow the [Purview setup runbook](../docs/operations/purview-setup-runbook.md)
for roles, certificate handling, and bounded validation.

## Recovery

If Plan stops, the setup UI identifies the safe boundary that stopped—configuration,
local prerequisites/Bicep, Azure account or region selection, Azure SQL regional
availability, Azure What-If, Agent ID blueprint validation, or changing inputs.
Correct that item, select **Review and run Plan again**, review the current inputs,
and confirm Plan again. Apply and Resume remain unavailable until Plan produces one
apply-ready fingerprint.

`doctor` checks the Windows Azure CLI/Bicep path through the same command boundary
used by Plan and Apply. `diagnose` can still write a safe bundle when configuration is
missing or invalid; in that case it reports configuration as unavailable and includes
no deployment identifiers.

If an accepted deployment stops:

```bash
./gateway status
./gateway diagnose
./gateway resume
```

On Windows PowerShell or Command Prompt, use:

```powershell
.\gateway.cmd status
.\gateway.cmd diagnose
.\gateway.cmd resume
```

Review the reported failure and correct its cause before Resume. Do not edit or
delete `.bootstrap/`, manually replay completed tenant operations, access retained
messages, or run a second bootstrap against the same deployment.

If Setup itself was closed or restarted, the terminal sequence above is the verified
path. Setup also implements the equivalent browser exchange—a read-only Resume
review, an in-memory single-use authorization handoff, and a separate
confirmation—but that path is still pending validation against preserved stopped
state.

Database recovery, one-shot manual database repair, and Admin UI upgrade are
deliberately bounded commands. Use them only when the bootstrap identifies that
exact eligible state and follow the linked [operations guide](../operations/README.md).

If a completed resource group was deleted, preserved tenant objects and deleted
resource-group credentials no longer share one lifecycle. Bootstrap refuses to
replay that state. Use a separately reviewed disaster-recovery procedure or a new
isolated deployment.

Bootstrap has no destroy mode and does not authorize cleanup, historical replay,
retained-message access, or SQL finalization.

### Reading the exact provider cause

A stopped step names the provider error codes and the correlation ID it received,
for example `Provider error codes: InvalidTemplateDeployment >
CanNotCreateMultipleFreeAccounts.` Those bounded identifiers appear in the terminal,
in the Setup timeline, and in the persisted checkpoint.

The unfiltered provider text stays local. Bootstrap writes it to
`.bootstrap/diagnostics/`, which is ignored by Git and readable only by the account
that ran the command. Read it yourself when a code is not enough; never paste it into
an issue, a chat, or a shared log, because provider bodies can contain identities,
headers, and other tenant data.

### Prompt Shields free-tier capacity

Azure allows one free Cognitive Services account per account type per subscription.
If `promptShield.enabled` is `true` with a free `skuName` such as `F0` and another
free Content Safety account already exists anywhere in the subscription, ARM rejects
the whole workload template during preflight and records no deployment, so there is
nothing to read back.

Bootstrap detects that conflict read-only during Plan and again before the workload
deployment, and names the conflicting account.

A deleted account still counts. Deleting a Content Safety account, or the resource
group that holds it, leaves it *soft-deleted*: it keeps its free-tier slot for the
rest of its retention window and never appears in a resource listing. A subscription
that looks completely clean can therefore fail every retry with the identical
`CanNotCreateMultipleFreeAccounts` rejection. List whatever still holds a slot with
`az cognitiveservices account list-deleted -o table`.

Resolve the conflict in exactly one way, then run Resume:

- purge the named account to release its slot, with `az cognitiveservices account
  purge --location <region> --resource-group <group> --name <account>`,
- set `promptShield.skuName` to a paid SKU such as `S0`, or
- set `promptShield.enabled` to `false` and configure Prompt Shields after base
  verification.

### Starting over from a clean initial state

Resume continues the deployment you already own. When you instead want the very
first state again, create a *new* deployment identity rather than repointing
preserved state at existing resources:

1. Confirm the current deployment is one you are willing to abandon. Bootstrap never
   deletes Azure resources, so anything already created stays until you remove it.
2. Remove the abandoned resource groups yourself, in the portal or with your own
   authorized `az group delete`. A Container Apps environment also creates an
   infrastructure group named `ME_<environment>_<resourceGroup>_<region>`; delete that
   too. Deleting the group is not sufficient for Content Safety: the account inside it
   becomes soft-deleted and keeps its free-tier slot, so purge it as well with
   `az cognitiveservices account purge --location <region> --resource-group <group>
   --name <account>`. Leaving either behind blocks the next deployment exactly as
   described above.
3. Move the existing configuration aside rather than editing it in place:
   `mv bootstrap/config.json bootstrap/config.json.previous`.
4. Run `.\gateway.cmd setup` (Windows) or `./gateway setup` (macOS, Linux). Setup
   generates a new project name, a new deployment ownership ID, and a new resource
   group, then writes a fresh `bootstrap/config.json` and a fresh ignored `.bootstrap/`
   ledger beside it.
5. Run Plan, review it, and confirm Apply.

Do not delete `.bootstrap/` to force a stopped deployment forward. That state is the
only record of what was already created in your tenant, and removing it makes the
next run unable to tell an owned resource from someone else's.

## After verification

A successful `up`, `resume`, or `verify` ends with a framed completion summary rather
than a single line. It states when the run finished in your local clock with the UTC
offset spelled out, how long it took, how many steps completed, the deployment,
resource group, region, subscription, readiness tiers, agent admission, the state
ledger path, the verified endpoints, and the numbered next steps. The guided Setup UI
renders the same facts on its Progress and Finish pages from the same event, so the
terminal and the browser cannot disagree about when or how the run ended.

Open the hosted Admin UI with `./gateway open`, sign in as a
`Gateway.Administrator`, register an external agent, and store the one-time Gateway
key immediately. See the root [quickstart](../README.md#sign-in-and-register-an-agent)
and [sample client](../README.md#send-a-sample-interaction).

Additional references:

- [Entra setup](../docs/operations/entra-setup-runbook.md)
- [Agent 365 observability](../docs/operations/agent365-observability-setup.md)
- [Backup and recovery](../docs/operations/backup-recovery.md)
- [Upgrade strategy](../docs/operations/upgrade-strategy.md)
- [Infrastructure assets](../infrastructure/README.md)
