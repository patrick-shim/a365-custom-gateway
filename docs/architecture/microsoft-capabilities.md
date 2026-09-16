# Microsoft provider contracts

This guide records the contracts used by the retained Gateway adapters and
deployment source. It is not a fresh provider-documentation review or proof of a
live tenant's capabilities. Revalidate provider availability and permissions during
deployment planning. Completion belongs only in
[MILESTONES.md](../../MILESTONES.md); current context belongs in
[project state](../project-state.md).

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
Both are part of the retained execution design; no active deployment is inferred.
Registration and Settings can submit reviewed configuration through the same
application service, including deferred consent for a newly created blueprint.

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

## Azure AI Content Safety

Prompt Shields calls POST /contentsafety/text:shieldPrompt with API version
2024-09-01. The retained adapter uses ManagedIdentityCredential and resource-scoped
Cognitive Services User authority; it does not fall back to account keys or a
developer credential chain. An attack decision blocks, while required protection
fails closed on transport, authorization or schema ambiguity.

Guided fresh setup includes shared Content Safety in every preset. Per-agent
Prompt Shields usage is independent and optional. The source retains legacy
disabled capability configurations for bound recovery. Resource installation
alone does not prove a successful runtime decision.

Provider references:
[Prompt Shields operation](https://learn.microsoft.com/rest/api/contentsafety/text-operations/shield-prompt?view=rest-contentsafety-2024-09-01),
[Entra authentication](https://learn.microsoft.com/azure/ai-services/authentication).

## Azure deployment boundaries

| Area | Source requirement |
|---|---|
| Region discovery | Target subscription's ARM location inventory; retain canonical region names and validate provider/SKU availability separately |
| SQL | Entra-only authentication and private access |
| Key Vault | Scoped identity/RBAC access and exact certificate secret binding |
| Container Apps | Managed identities and immutable candidate image bindings |
| Service Bus | Separate registration and protection queues with duplicate-safe consumers |
| Windows executor | Private application/SCM access, package integrity and exact worker caller |
| Upgrade | Preserved bootstrap state plus a separate exact source/resource/schema-bound plan |

All project Azure operations use the tenant and subscription pinned in
[AGENTS.md](../../AGENTS.md). Historical configuration files and incident-specific
repair scripts do not establish a current target. Retained
[upgrade tooling](../../operations/gateway-upgrade.md) must satisfy its own
prerequisites and actual verification limits.

Provider references:
[ARM location inventory](https://learn.microsoft.com/rest/api/resources/subscriptions/list-locations?view=rest-resources-2022-12-01),
[managed identity authorization considerations](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/managed-identity-best-practice-recommendations#limitation-of-using-managed-identities-for-authorization).

## Unsupported assumptions

The retained design does not assume ordinary applications can be converted into
typed blueprints, worker/app-only Registry creation, client-secret OBO fallback,
an unvalidated REST replacement for compliance policy authoring, or write-only
Purview APIs providing analytics retrieval. Provider readback, runtime
certification and project milestone completion serve different purposes.
