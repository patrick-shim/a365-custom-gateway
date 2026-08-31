# Microsoft capability validation

This matrix records current official contracts relied on by the Gateway. Code,
tests, deployed evidence, and current Microsoft documentation take precedence over
older design notes or prototypes.

Last reviewed: 2026-08-31.

## Agent Identity and Agent 365

| Capability | Gateway contract | Status |
|---|---|---|
| Agent Identity blueprint catalog | Typed Graph endpoints and `managerApplications` compatibility | Preview; fail closed on unknown shapes |
| Blueprint principal and federation | Microsoft Graph Agent Identity endpoints | Preview; exact readback required |
| Child Agent ID creation | Microsoft Graph Agent Identity endpoints | Preview; one child per registration |
| Agent 365 Registry create | Delegated, CLI-compatible request behavior | Preview; user-only OBO, one POST |
| Agent 365 observability | OTLP with `Agent365.Observability.OtelWrite` | Documented service contract |

The worker Graph application-role allowlist is exactly `Application.Read.All`,
`AppRoleAssignment.ReadWrite.All`, `AgentIdentityBlueprint.Create`,
`AgentIdentityBlueprint.AddRemoveCreds.All`,
`AgentIdentityBlueprintPrincipal.Create`, `AgentIdentityBlueprint.Read.All`,
`AgentIdentity.Create.All`, and `AgentIdentity.Read.All`.

Registry permissions are the API app's admin-consented delegated
`AgentRegistration.Read.All` and `AgentRegistration.ReadWrite.All` scopes, acquired
through OBO. They are not worker roles.

- [Agent 365 developer documentation](https://learn.microsoft.com/microsoft-agent-365/developer/)
- [Microsoft Graph permissions](https://learn.microsoft.com/graph/permissions-reference)
- [On-behalf-of flow](https://learn.microsoft.com/entra/identity-platform/v2-oauth2-on-behalf-of-flow)
- [Workload identity federation](https://learn.microsoft.com/entra/workload-id/workload-identity-federation)

## Microsoft Purview

| Capability | Contract | Status |
|---|---|---|
| Runtime content processing | Graph v1.0 `processContent` | GA; honor per-activity inline/offline mode |
| Content activity submission | Graph v1.0 `contentActivities` | GA |
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

- [Configure Purview for custom AI applications](https://learn.microsoft.com/purview/developer/configurepurview)
- [Use the Purview data-security APIs](https://learn.microsoft.com/purview/developer/use-the-api)
- [Process content](https://learn.microsoft.com/graph/api/userdatasecurityandgovernance-processcontent?view=graph-rest-1.0)
- [Create content activity](https://learn.microsoft.com/graph/api/activitiescontainer-post-contentactivities?view=graph-rest-1.0)
- [New-DlpCompliancePolicy](https://learn.microsoft.com/powershell/module/exchangepowershell/new-dlpcompliancepolicy?view=exchange-ps)
- [New-DlpComplianceRule](https://learn.microsoft.com/powershell/module/exchangepowershell/new-dlpcompliancerule?view=exchange-ps)
- [Managed identity token caching](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/managed-identity-best-practice-recommendations#limitation-of-using-managed-identities-for-authorization)

## Azure AI Content Safety

Prompt Shields calls `POST {endpoint}/contentsafety/text:shieldPrompt` with API
version `2024-09-01` using managed identity. `attackDetected=true` blocks; transport,
authorization, or schema ambiguity fails closed. Account keys are disabled.

- [Prompt Shields quickstart](https://learn.microsoft.com/azure/ai-services/content-safety/quickstart-jailbreak)
- [Prompt Shields REST operation](https://learn.microsoft.com/rest/api/contentsafety/text-operations/shield-prompt?view=rest-contentsafety-2024-09-01)

## Azure platform

| Area | Required boundary |
|---|---|
| Azure SQL | Entra-only authentication, private endpoint, zero firewall rules |
| Key Vault | RBAC, local/public access disabled after setup, exact secret scope |
| Container Apps | Managed identities and immutable image digests |
| Service Bus | Dedicated v3 queue and duplicate-safe consumers |
| Container Registry | Dedicated pull identity avoids first-pull identity cycles |

## Unsupported assumptions

Do not implement or claim conversion of an ordinary application into a typed
blueprint, worker/app-only Registry creation, a client-secret OBO fallback, Purview
policy authoring through an unvalidated REST endpoint, Purview analytics retrieval
through write-only APIs, response-side blocking for offline processing, or
Microsoft-side completion from Gateway persistence alone.
