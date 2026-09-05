# Microsoft capability validation

This matrix records current official contracts relied on by the Gateway. Code,
tests, deployed evidence, and current Microsoft documentation take precedence over
older design notes or prototypes.

Last reviewed against official Microsoft Learn: 2026-09-05.

## Agent Identity and Agent 365

| Capability | Gateway contract | Status |
|---|---|---|
| Agent Identity blueprint catalog | Graph v1.0 typed application cast and `managerApplications` compatibility | Documented v1.0 surface; tenant permission availability can still vary |
| Blueprint principal and federation | Graph v1.0 Agent Identity casts plus application FIC | Documented v1.0 surface; exact readback required |
| Child Agent ID creation | `POST /v1.0/servicePrincipals/microsoft.graph.agentIdentity` | `201 Created`; one distinct child per active registration |
| Agent 365 Registry create | `POST /beta/copilot/agentRegistrations` | Beta and unsupported for production; Gateway uses user-only delegated OBO and at most one POST |
| Agent 365 observability | S2S OTLP/HTTP JSON route with `Agent365.Observability.OtelWrite` | Documented direct OTel service contract |

The worker Graph application-role allowlist is exactly `Application.Read.All`,
`AppRoleAssignment.ReadWrite.All`, `AgentIdentityBlueprint.Create`,
`AgentIdentityBlueprint.AddRemoveCreds.All`,
`AgentIdentityBlueprintPrincipal.Create`, `AgentIdentityBlueprint.Read.All`,
`AgentIdentity.Create.All`, and `AgentIdentity.Read.All`.

Registry permissions are the API app's admin-consented delegated
`AgentRegistration.Read.All` and `AgentRegistration.ReadWrite.All` scopes, acquired
through OBO. They are not worker roles. Microsoft also documents application
permission for Registry, but the Gateway deliberately does not use that mode: its
product boundary requires an accountable signed-in administrator.

Registry create succeeds only on the documented `201 Created` response. Before the
single POST, the Gateway persists a creator-bound planned ID. A timeout, transport
failure, retryable HTTP status, or non-201 2xx is ambiguous and permits only exact
GET of that planned ID; it never permits another POST.

The direct Agent 365 S2S telemetry route is
`POST https://agent365.svc.cloud.microsoft/observabilityService/tenants/{tenantId}/otlp/agents/{agentId}/traces?api-version=1`.
The URL agent ID is the child Agent Identity app ID and must match the app-only
token's `appid` or `azp`; the token must carry
`Agent365.Observability.OtelWrite`.

- [Agent 365 developer documentation](https://learn.microsoft.com/microsoft-agent-365/developer/)
- [Create Agent 365 agent registration](https://learn.microsoft.com/microsoft-365/copilot/extensibility/api/admin-settings/agent-registration/agentregistration-create)
- [Direct Agent 365 OpenTelemetry integration](https://learn.microsoft.com/microsoft-agent-365/developer/direct-open-telemetry-integration)
- [Create Agent Identity blueprint](https://learn.microsoft.com/graph/api/agentidentityblueprint-post?view=graph-rest-1.0)
- [Create child Agent Identity](https://learn.microsoft.com/graph/api/agentidentity-post?view=graph-rest-1.0)
- [Microsoft Graph permissions](https://learn.microsoft.com/graph/permissions-reference)
- [On-behalf-of flow](https://learn.microsoft.com/entra/identity-platform/v2-oauth2-on-behalf-of-flow)
- [Workload identity federation](https://learn.microsoft.com/entra/workload-id/workload-identity-federation)

## Microsoft Purview

| Capability | Contract | Status |
|---|---|---|
| Protection-scope computation | Graph v1.0 `/users/{userId}/dataSecurityAndGovernance/protectionScopes/compute` | Application permission `ProtectionScopes.Compute.User`; cache returned ETag |
| Runtime content processing | Graph v1.0 `/users/{userId}/dataSecurityAndGovernance/processContent` | Application permission `Content.Process.User`; honor `200`, `202`, or `204` and per-activity inline/offline mode |
| Content activity submission | Graph v1.0 `/users/{userId}/dataSecurityAndGovernance/activities/contentActivities` | Application permission `ContentActivity.Write`; success is `201 Created` |
| Tenant sensitive-information-type inventory | Security & Compliance PowerShell `Get-DlpSensitiveInformationType` after `Connect-IPPSSession` | Windows only; current module documentation says Security & Compliance PowerShell is unavailable in PowerShell 7 on macOS and Linux; tenant RBAC controls availability |
| Know Your Data setup | `New/Get/Set-FeatureConfiguration` | Public Preview; tenant availability varies |
| Custom-app DLP authoring | Security & Compliance PowerShell | Exact readback required |

The policy scopes are deliberately different:

- Know Your Data uses fixed enterprise-AI-apps location
  `ee1680d0-702f-4090-b26c-c49091e86531`, `LocationSource=Entra`,
  `LocationType=Group`.
- DLP uses the protected blueprint application ID, `LocationSource=Entra`,
  `LocationType=Individual`.
- Both use `EnforcementPlanes=Application`.

Directory assignment readback does not prove a managed-identity token already
contains the roles. Microsoft documents managed-identity token caching by resource
URI; runtime enablement must wait for safe token-role or data-plane verification.
Never inspect or emit raw tokens.

SIT selection is tenant-backed, not a bundled catalog. The no-argument inventory
cmdlet returns the types defined for the organization. The Gateway keys a selection
by the returned GUID, retains its exact Unicode `Name` because the documented
`New-DlpComplianceRule -ContentContainsSensitiveInformation` shape uses `Name`, and
re-resolves the GUID before use. Exact GUID filtering is mandatory: Microsoft warns
that a null or nonexistent `-Identity` can return the full inventory. Microsoft does
not document a Graph endpoint for enumerating this catalog or a cmdlet-specific
least-privilege role mapping, so Setup probes authorization and fails closed instead
of guessing either contract.

The core bootstrap remains supported on Windows, macOS, and Linux. The optional SIT
inventory and policy-authoring path is Windows-only because Microsoft's current
Exchange Online module documentation says `Connect-IPPSSession`, and therefore
Security & Compliance PowerShell, is unavailable in PowerShell 7 on macOS and
Linux. The Gateway does not substitute a static catalog or an unvalidated REST
endpoint on those platforms.

- [Configure Purview for custom AI applications](https://learn.microsoft.com/purview/developer/configurepurview)
- [Use the Purview data-security APIs](https://learn.microsoft.com/purview/developer/use-the-api)
- [Compute protection scopes](https://learn.microsoft.com/graph/api/userprotectionscopecontainer-compute?view=graph-rest-1.0)
- [Process content](https://learn.microsoft.com/graph/api/userdatasecurityandgovernance-processcontent?view=graph-rest-1.0)
- [Create content activity](https://learn.microsoft.com/graph/api/activitiescontainer-post-contentactivities?view=graph-rest-1.0)
- [New-DlpCompliancePolicy](https://learn.microsoft.com/powershell/module/exchangepowershell/new-dlpcompliancepolicy?view=exchange-ps)
- [New-DlpComplianceRule](https://learn.microsoft.com/powershell/module/exchangepowershell/new-dlpcompliancerule?view=exchange-ps)
- [Get-DlpSensitiveInformationType](https://learn.microsoft.com/powershell/module/exchangepowershell/get-dlpsensitiveinformationtype?view=exchange-ps)
- [Connect to Security & Compliance PowerShell](https://learn.microsoft.com/powershell/exchange/connect-to-scc-powershell?view=exchange-ps)
- [Exchange Online PowerShell module operating-system support](https://learn.microsoft.com/powershell/exchange/exchange-online-powershell-v2?view=exchange-ps#supported-operating-systems-for-the-exchange-online-powershell-module)
- [Managed identity token caching](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/managed-identity-best-practice-recommendations#limitation-of-using-managed-identities-for-authorization)

## Azure AI Content Safety

Prompt Shields calls `POST {endpoint}/contentsafety/text:shieldPrompt` with API
version `2024-09-01`. Microsoft documents key and Microsoft Entra authentication;
the Gateway deliberately uses `ManagedIdentityCredential` only and assigns the API
managed identity the built-in `Cognitive Services User` role on the resource. It
has no developer, CLI, environment, workload, or client-secret credential-chain
fallback. `attackDetected=true` blocks;
transport, authorization, or schema ambiguity fails closed. Account keys are
disabled.

- [Prompt Shields quickstart](https://learn.microsoft.com/azure/ai-services/content-safety/quickstart-jailbreak)
- [Prompt Shields REST operation](https://learn.microsoft.com/rest/api/contentsafety/text-operations/shield-prompt?view=rest-contentsafety-2024-09-01)
- [Authenticate Foundry Tools with Microsoft Entra ID](https://learn.microsoft.com/azure/ai-services/authentication)

## Azure platform

| Area | Required boundary |
|---|---|
| Deployment region discovery | Use the target subscription's ARM `Subscriptions - List Locations` 2022-12-01 response. Show `displayName`, persist canonical `name`, follow `nextLink`, and accept only `type=Region` with `metadata.regionType=Physical`. A listed region is not proof that every provider or SKU is available there. |
| Azure SQL | Entra-only authentication, private endpoint, zero firewall rules |
| Key Vault | RBAC, local/public access disabled after setup, exact secret scope |
| Container Apps | Managed identities and immutable image digests |
| Service Bus | Dedicated v3 queue and duplicate-safe consumers |
| Container Registry | Dedicated pull identity avoids first-pull identity cycles |

The locations API uses Azure-authenticated subscription access. Azure CLI's
`az account list-locations` is a Core GA surface for the same subscription-specific
inventory. Microsoft's public region table identifies **Korea Central** by the
programmatic name `koreacentral`.

- [ARM Subscriptions - List Locations](https://learn.microsoft.com/rest/api/resources/subscriptions/list-locations?view=rest-resources-2022-12-01)
- [Azure CLI account commands](https://learn.microsoft.com/cli/azure/account?view=azure-cli-latest#az-account-list-locations)
- [Azure regions and programmatic names](https://learn.microsoft.com/azure/reliability/regions-list)

## Unsupported assumptions

Do not implement or claim conversion of an ordinary application into a typed
blueprint, worker/app-only Registry creation, a client-secret OBO fallback, Purview
SIT inventory or policy authoring through an unvalidated REST endpoint, substituting
Graph sensitivity labels for Purview sensitive information types, Purview analytics
retrieval through write-only APIs, response-side blocking for offline processing,
or Microsoft-side completion from Gateway persistence alone.
