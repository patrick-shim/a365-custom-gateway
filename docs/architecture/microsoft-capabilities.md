# Microsoft provider contracts

Contracts for the **essential Microsoft product services** this Gateway exists
to use: **Entra, Graph, Agent 365, Purview, and Prompt Shields**.

These are **not** infrastructure. Gateway hosting must have **zero Microsoft
dependence** (PostgreSQL, RabbitMQ, Vault/OpenBao, S3, Compose/Kubernetes on
AWS/GCP/on-prem). Do not require Azure SQL, Service Bus, Key Vault, Container
Apps, ACR, or Blob to run.

UI modernization does not change these provider boundaries. Product scope:
[product brief](../spec/product-brief.md). This is not a fresh provider-docs
review or proof of a live tenant's capabilities. Revalidate permissions during
deployment planning.

## Agent Identity and Agent 365

| Capability | Retained Gateway contract |
|---|---|
| Blueprint catalog | Graph v1.0 typed Agent Identity application casts and reviewed managerApplications |
| Blueprint principal and federation | Graph v1.0 Agent Identity casts and application federated identity credentials, with exact readback |
| Child Agent ID | POST /v1.0/servicePrincipals/microsoft.graph.agentIdentity; a distinct child for each registration |
| Registry creation | POST /beta/copilot/agentRegistrations through user-only delegated OBO, at most once per operation lineage |
| Observability | Direct S2S OTLP/HTTP JSON export with Agent365.Observability.OtelWrite |

The worker Graph application-role allowlist is Application.Read.All,
AppRoleAssignment.ReadWrite.All, AgentIdentityBlueprint.Create,
AgentIdentityBlueprint.AddRemoveCreds.All,
AgentIdentityBlueprintPrincipal.Create, AgentIdentityBlueprint.Read.All,
AgentIdentity.Create.All and AgentIdentity.Read.All.

Registry uses the API application's delegated AgentRegistration.Read.All and
AgentRegistration.ReadWrite.All scopes. The Gateway requires a signed-in
Administrator and does not delegate Registry creation to the worker.
The source gates Registry beta to explicitly acknowledged development use;
staging and production registration admission remain closed.

The API persists a creator-bound planned Registry ID before its single POST and
accepts the expected 201 response. An ambiguous result permits exact GET of that
planned ID, never another create attempt. Local Gateway persistence does not
replace Microsoft-side final verification.

The exporter uses the direct route:

```text
POST https://agent365.svc.cloud.microsoft/observabilityService/tenants/{tenantId}/otlp/agents/{agentId}/traces?api-version=1
```

The route's agent ID is the child Agent Identity application ID. The app-only
token must bind to that child and carry Agent365.Observability.OtelWrite.

The accepted operation names are `invoke_agent`, `execute_tool`, `chat` and
`output_messages`. The public activity contract also retains Custom, which does
not have an Agent 365 export mapping. Optional OTLP result details and a `sent`
sink indicate only the evidence reported by that endpoint; an absent or unrouted
destination is not independently verified portal landing.

Provider references:
[Agent 365 registration](https://learn.microsoft.com/microsoft-365/copilot/extensibility/api/admin-settings/agent-registration/agentregistration-create),
[direct OpenTelemetry integration](https://learn.microsoft.com/microsoft-agent-365/developer/direct-open-telemetry-integration),
[blueprint creation](https://learn.microsoft.com/graph/api/agentidentityblueprint-post?view=graph-rest-1.0),
[child identity creation](https://learn.microsoft.com/graph/api/agentidentity-post?view=graph-rest-1.0),
[Graph permissions](https://learn.microsoft.com/graph/permissions-reference),
[OBO](https://learn.microsoft.com/entra/identity-platform/v2-oauth2-on-behalf-of-flow).

## Purview runtime and policy administration

| Capability | Retained Gateway contract |
|---|---|
| Protection scopes | Graph v1.0 /users/{userId}/dataSecurityAndGovernance/protectionScopes/compute; ProtectionScopes.Compute.User |
| Content processing | Graph v1.0 /users/{userId}/dataSecurityAndGovernance/processContent; Content.Process.User |
| Content activity | Graph v1.0 /users/{userId}/dataSecurityAndGovernance/activities/contentActivities; ContentActivity.Write |
| Tenant SIT inventory | Get-DlpSensitiveInformationType after Connect-IPPSSession |
| Know Your Data | Fixed-scope New/Get/Set-FeatureConfiguration operations |
| DLP authoring | Bounded Security & Compliance PowerShell policy/rule operations with exact readback |

Runtime processing distinguishes inline decisions from accepted/offline work.
A successful HTTP response alone is not an allow/block verdict. DownloadText
processing can be offline and cannot then prove response-side blocking.

Know Your Data uses Entra Group location
`ee1680d0-702f-4090-b26c-c49091e86531`. DLP uses the reusable blueprint application
as an Entra Individual location. Both use the Application plane. Policies shared
by a blueprint are not isolated to one registration.

SIT choices bind the tenant inventory GUID and exact Unicode name. The source
re-resolves exact inventory membership rather than accepting a static catalog,
free-text type or Graph sensitivity label. Multiple selected SITs use OR semantics
with independent count/confidence thresholds.
Native settings operations share one fresh catalog within an invocation, import
only their required commands and check expiry immediately before writes. This
is bounded execution, not background catalog caching or automatic authority
renewal. A newly reviewed existing-profile reconciliation can accept the current
generation for unchanged settings and invalidate old proof; its provider work
remains read-only.

Four policy modes map to the provider: Enforce to Enable, SimulationWithTips to
TestWithNotifications, SimulationWithoutTips to TestWithoutNotifications, and
Disabled to Disable. Verified simulation or configured-off status is distinct
from certified enforcement.

Directory-role readback and usable runtime-token roles are separate evidence.
The runtime certification path safely verifies roles and behavior without exposing
raw tokens. It binds the current profile, inventory, identity and approved samples;
stale or uncertain results cannot establish readiness.

Interactive connection uses the bounded Windows companion. Noninteractive policy
administration uses the private [Windows executor](purview-windows-executor.md).
Both are part of the execution design. M5's private Windows runtime qualification
does not establish a tenant connection, provider authorization or policy readiness.
Registration and Settings can submit reviewed configuration through the same
application service, including deferred consent for a newly created blueprint.

The connection verifier requires the automation identity's separate Security &
Compliance service-principal reference to match both ObjectId and AppId. Retained
Entra preparation and the interactive companion do not create that reference.
Connection/inventory proof currently expires after 15 minutes; certification
cannot outlive it. These are source prerequisites and lifetime constraints, not
current tenant observations.

Provider references:
[custom AI configuration](https://learn.microsoft.com/purview/developer/configurepurview),
[data-security APIs](https://learn.microsoft.com/purview/developer/use-the-api),
[compute protection scopes](https://learn.microsoft.com/graph/api/userprotectionscopecontainer-compute?view=graph-rest-1.0),
[process content](https://learn.microsoft.com/graph/api/userdatasecurityandgovernance-processcontent?view=graph-rest-1.0),
[content activities](https://learn.microsoft.com/graph/api/activitiescontainer-post-contentactivities?view=graph-rest-1.0),
[SIT inventory](https://learn.microsoft.com/powershell/module/exchangepowershell/get-dlpsensitiveinformationtype?view=exchange-ps),
[DLP policy](https://learn.microsoft.com/powershell/module/exchangepowershell/new-dlpcompliancepolicy?view=exchange-ps),
[DLP rule](https://learn.microsoft.com/powershell/module/exchangepowershell/new-dlpcompliancerule?view=exchange-ps),
[module platform support](https://learn.microsoft.com/powershell/exchange/exchange-online-powershell-v2?view=exchange-ps#supported-operating-systems-for-the-exchange-online-powershell-module).

## Prompt Shields (essential product service)

Prompt Shields is an **essential** Gateway capability. The adapter calls Microsoft
content safety `POST /contentsafety/text:shieldPrompt` (API version 2024-09-01)
as a **product API**, not as a reason to host the Gateway on Azure infrastructure.
Portable runtimes authenticate with Vault-issued or non-Microsoft workload
credentials suitable for that API; the legacy Azure infra profile may still use
ManagedIdentityCredential. Account-key fallbacks are not used. An attack decision
blocks; required protection fails closed on transport, authorization, or schema
ambiguity.

Per-agent On/Off is a usage control, not a statement that Prompt Shields is
optional to the product. API reachability alone does not prove a successful
runtime decision.

Provider references (when using Azure AI Content Safety as the provider):
[Prompt Shields operation](https://learn.microsoft.com/rest/api/contentsafety/text-operations/shield-prompt?view=rest-contentsafety-2024-09-01),
[Entra authentication](https://learn.microsoft.com/azure/ai-services/authentication).

## Deployment boundaries (portable vs legacy)

| Area | Portable target | Legacy Azure profile (transitional) |
|---|---|---|
| Database | PostgreSQL (+ SQLite local/dev) | Azure SQL |
| Queues | RabbitMQ; duplicate-safe consumers | Service Bus |
| Secrets | OpenBao / HashiCorp Vault | Key Vault |
| Compute / images | Compose/Kubernetes; any OCI registry digests | Container Apps + ACR |
| Windows executor | Private Windows host; package integrity; exact worker caller | Windows App Service variant of the same contract |
| Upgrade | Image + schema plan for the portable profile | [Azure upgrade tooling](../../operations/gateway-upgrade.md) |

Historical configuration does not establish a current target. Microsoft Graph /
Registry / Purview API operations use the exact Entra tenant bound by the accepted
configuration regardless of where containers run.

## Unsupported assumptions

The retained design does not assume ordinary applications can be converted into
typed blueprints, worker/app-only Registry creation, client-secret OBO fallback,
an unvalidated REST replacement for compliance policy authoring, or write-only
Purview APIs providing analytics retrieval. Provider readback, runtime
certification and project milestone completion serve different purposes.
