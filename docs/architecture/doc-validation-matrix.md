# Phase 1: Documentation Validation Matrix

## Executive Summary

This document validates every Microsoft API, SDK, CLI command, permission, and capability required by the A365 Custom Gateway against official Microsoft Learn documentation. Research was conducted on 2026-08-23.

### Key Findings

1. **Agent 365 Blueprint API is GA** (v1.0 Graph) but the **Agent Registration API is beta/preview** (`/beta/copilot/agentRegistrations`) — not supported for production use.
2. **`managerApplications` is restricted to Microsoft first-party apps only** — the gateway cannot designate itself as a manager application, requiring higher-privilege permissions for agent identity creation.
3. **Agent instance provisioning has no REST API** — requires admin approval through M365 admin center or Teams.
4. **Purview `processContent` API is GA (v1.0)** — supports both inline evaluation (block/allow) and offline audit. User context is mandatory.
5. **Purview DLP policies for custom apps must be created via PowerShell** — portal UI does not support this.
6. **No Purview APIs exist to read data out** — APIs are input-only.
7. **Observability has a documented OTLP endpoint** — telemetry export via `agent365.svc.cloud.microsoft` with `Agent365.Observability.OtelWrite` permission.

### Decision Impact

| Gateway Feature | Status | Decision |
|---|---|---|
| Agent registration | Partially supported | Use CLI worker + beta Graph API with preview caveat |
| Agent provisioning (instance) | Not programmatically supported | Manual admin approval step required |
| Blueprint management | GA | Use v1.0 Graph API directly |
| Observability export to Agent 365 | GA | Use OTLP endpoint with documented SDK |
| Purview inline evaluation | GA | Use `processContent` with `evaluateInline` mode |
| Purview audit logging | GA | Use `contentActivities` API |
| Entra app management | GA | Use Graph API with `Application.ReadWrite.OwnedBy` |

---

## 1. Microsoft Agent 365

### 1.1 Blueprint Management

| Field | Value |
|---|---|
| **Requirement** | Create and manage agent identity blueprints |
| **Doc URL** | https://learn.microsoft.com/graph/api/resources/agentidentityblueprint |
| **Mechanism** | Microsoft Graph v1.0 REST API |
| **Endpoints** | `POST /v1.0/applications/microsoft.graph.agentIdentityBlueprint` (Create) |
| | `GET /v1.0/applications/{id}/microsoft.graph.agentIdentityBlueprint` (Get) |
| | `PATCH /v1.0/applications/{id}/microsoft.graph.agentIdentityBlueprint` (Update) |
| | `PATCH /v1.0/applications(uniqueName='{name}')/microsoft.graph.agentIdentityBlueprint` (Upsert, with `Prefer: create-if-missing`) |
| **Auth Mode** | Application or Delegated |
| **Permission** | `AgentIdentityBlueprint.ReadWrite.All` |
| **Admin Consent** | Yes |
| **Status** | **v1.0 GA** (but permission may be beta — not visible in Entra admin center) |
| **Limitations** | `managerApplications` property only accepts Microsoft first-party app IDs. Custom gateway cannot add itself. Max 10 entries. |
| **Decision** | Use Graph API directly. Accept that gateway requires `AgentIdentityBlueprintPrincipal.ReadWrite.All` since it cannot use `managerApplications` shortcut. |

### 1.2 Agent Registration

| Field | Value |
|---|---|
| **Requirement** | Register agents in the Agent 365 registry |
| **Doc URL** | https://learn.microsoft.com/microsoft-365/copilot/extensibility/api/admin-settings/agent-registration/overview |
| **Mechanism** | Microsoft Graph **beta** REST API |
| **Endpoints** | `POST /beta/copilot/agentRegistrations` (Create) |
| | `GET /beta/copilot/agentRegistrations/{id}` (Get) |
| | `PATCH /beta/copilot/agentRegistrations/{id}` (Update) |
| | `DELETE /beta/copilot/agentRegistrations/{id}` (Delete) |
| **Auth Mode** | Application or Delegated |
| **Permission** | `AgentRegistration.ReadWrite.All` |
| **Admin Consent** | Yes |
| **Status** | **PREVIEW/BETA — "Use in production applications is not supported"** |
| **Limitations** | Beta only. Not available in US Gov L4/L5 or China (21Vianet). Required properties: `displayName`, `createdBy`, `sourceCreatedDateTime`, `sourceLastModifiedDateTime`. |
| **Decision** | **Use with explicit preview caveat.** Implement behind a feature flag. Provide CLI-based fallback (`a365 setup all`) as alternative provisioning path. Document preview dependency clearly. |

### 1.3 Agent Identity and Instance Management

| Field | Value |
|---|---|
| **Requirement** | Create agent identity service principals and instances |
| **Doc URL** | https://learn.microsoft.com/graph/api/resources/agentid-platform-overview |
| **Mechanism** | Microsoft Graph v1.0 (Agent Identity), M365 Admin Center (instances) |
| **Endpoints** | `agentIdentity` on `/v1.0/servicePrincipals/{id}/microsoft.graph.agentIdentity` |
| | `agentIdentityBlueprintPrincipal` on `/v1.0/servicePrincipals/{id}` |
| **Permissions** | `AgentIdentityBlueprintPrincipal.Create` (beta), `AgentIdentity.Read.All` (beta), `AgentIdentity.ReadWrite.All` (beta) |
| **Status** | v1.0 Graph resource types, but **permissions are beta** |
| **Limitations** | **Instance creation requires admin approval through M365 admin center or Teams — no REST API for programmatic instance provisioning.** Instance lifecycle: developer publishes -> user requests -> admin approves -> Teams creates instance. |
| **Decision** | Gateway creates blueprint + blueprint principal + registers in Agent 365 registry. Instance provisioning is a **manual admin approval step** — gateway tracks status as `AwaitingAdminApproval`. |

### 1.4 managerApplications

| Field | Value |
|---|---|
| **Requirement** | Configure the gateway as a manager application for blueprints |
| **Doc URL** | https://learn.microsoft.com/graph/api/resources/agentidentityblueprint?view=graph-rest-1.0#properties |
| **Mechanism** | Property on `agentIdentityBlueprint` resource |
| **Status** | GA (as a property) |
| **Limitations** | **Only Microsoft first-party application IDs can be designated as managers.** Third-party applications cannot be added. Max 10 entries. Not nullable. |
| **Decision** | **Gateway CANNOT use `managerApplications`.** Must use higher-privilege permissions (`AgentIdentityBlueprintPrincipal.ReadWrite.All`) instead of the lower-privilege `AgentIdentity.CreateAsManager` path. This is a documented platform constraint. |

### 1.5 Agent 365 CLI

| Field | Value |
|---|---|
| **Requirement** | CLI-based provisioning as fallback |
| **Doc URL** | https://learn.microsoft.com/microsoft-agent-365/developer/agent-365-cli |
| **Reference** | https://learn.microsoft.com/microsoft-agent-365/developer/reference/cli/ |
| **NuGet Package** | `Microsoft.Agents.A365.DevTools.Cli` (dotnet tool) |
| **Install** | `dotnet tool install --global Microsoft.Agents.A365.DevTools.Cli` |
| **Key Commands** | `a365 setup all`, `a365 setup blueprint`, `a365 cleanup`, `a365 publish` |
| **Requires** | .NET 8.0+, Azure Contributor + Agent ID Developer roles |
| **Status** | GA |
| **Limitations** | Interactive by default (browser-based auth). Some commands (MCP server registration) are CLI-only with no REST equivalent. Global Administrator required for OAuth2 permission grants. |
| **Decision** | Implement CLI worker as alternative provisioning path. Use `--agent-name` and non-interactive parameters where supported. |

### 1.6 Observability

| Field | Value |
|---|---|
| **Requirement** | Export agent telemetry to Agent 365 observability |
| **Doc URL** | https://learn.microsoft.com/microsoft-agent-365/developer/observability |
| **Direct OTel** | https://learn.microsoft.com/microsoft-agent-365/developer/direct-open-telemetry-integration |
| **Attributes** | https://learn.microsoft.com/microsoft-agent-365/developer/observability-attribute-reference |
| **Mechanism** | OTLP/HTTP `POST /traces` at `agent365.svc.cloud.microsoft` |
| **Permission** | `Agent365.Observability.OtelWrite` on audience `9b975845-388f-4429-889e-eab1ef63949c` |
| **Auth Modes** | S2S (client credentials) at `/observabilityService/...`, OBO at `/observability/...` |
| **NuGet Packages** | `Microsoft.Agents.A365.Observability`, `.Runtime`, `.Hosting` |
| **Span Operations** | `invoke_agent`, `execute_tool`, `chat`, `output_messages` |
| **Status** | GA |
| **Limitations** | Max 1MB request body. Rate limiting (429 with `Retry-After: 1`). Requires at least one user in tenant with M365 E7 or Agent 365 license. Data flows to Defender CloudAppEvents, Purview, M365 admin center. |
| **Decision** | Use Direct OTel integration path (OTLP/HTTP). Gateway maps external agent activities to documented span operations. Use S2S auth with `Agent365.Observability.OtelWrite`. |

---

## 2. Microsoft Purview

### 2.1 Compute Protection Scopes

| Field | Value |
|---|---|
| **Requirement** | Determine which policies apply to a user's AI interactions |
| **Doc URL** | https://learn.microsoft.com/graph/api/userprotectionscopecontainer-compute |
| **Tutorial** | https://learn.microsoft.com/purview/developer/use-the-api |
| **Mechanism** | Microsoft Graph v1.0 REST API |
| **Endpoint** | `POST /users/{userId}/dataSecurityAndGovernance/protectionScopes/compute` |
| **Auth Mode** | Application or Delegated |
| **Permission (least)** | `ProtectionScopes.Compute.User` |
| **Permission (higher)** | `ProtectionScopes.Compute.All` |
| **Admin Consent** | Yes |
| **Status** | **v1.0 GA** |
| **Limitations** | Not available in China (21Vianet). Personal Microsoft accounts not supported. Returns `executionMode`: `evaluateInline` or `evaluateOffline`. Cache ETag, re-poll every 60 minutes. |
| **Decision** | Call on first interaction per user session. Cache results with ETag. Re-compute when `protectionScopeState` returns `modified`. |

### 2.2 Process Content (Inline Policy Evaluation)

| Field | Value |
|---|---|
| **Requirement** | Evaluate prompts/responses against Purview DLP policies |
| **Doc URL** | https://learn.microsoft.com/graph/api/userdatasecurityandgovernance-processcontent |
| **Mechanism** | Microsoft Graph v1.0 REST API |
| **Endpoint** | `POST /users/{userId}/dataSecurityAndGovernance/processContent` |
| **Auth Mode** | Application or Delegated |
| **Permission (least)** | `Content.Process.User` |
| **Permission (higher)** | `Content.Process.All` |
| **Admin Consent** | Yes |
| **Status** | **v1.0 GA** |
| **Limitations** | **User context (Entra user ID) is mandatory** — no anonymous/service-account-only mode. When `executionMode` is `evaluateInline`, caller must block until API responds. Returns `policyActions` with `restrictAccess`/`block`. Also handles audit logging when called. Not available in China (21Vianet). |
| **Decision** | Use for both Enforce mode (inline, block on `restrictAccess`) and AuditOnly mode (offline, don't block). **Critical: Gateway must receive a valid user Entra object ID from the external agent — cannot fabricate this.** |

### 2.3 Content Activity (Audit Logging)

| Field | Value |
|---|---|
| **Requirement** | Submit AI interaction audit records to Purview |
| **Doc URL** | https://learn.microsoft.com/graph/api/activitiescontainer-post-contentactivities |
| **Mechanism** | Microsoft Graph v1.0 REST API |
| **Endpoint** | `POST /users/{userId}/dataSecurityAndGovernance/activities/contentActivities` |
| **Auth Mode** | Application or Delegated |
| **Permission** | `ContentActivity.Write` |
| **Admin Consent** | Yes |
| **Status** | **v1.0 GA** |
| **Limitations** | User context required. Input-only — no APIs to read data back out. Audit records appear in Activity Explorer as `ConnectedAIAppInteraction` record type. |
| **Decision** | Use when Purview is in AuditOnly mode and no DLP evaluation is needed. Also use as fallback when `processContent` is not appropriate. |

### 2.4 Purview Operational Requirements

| Field | Value |
|---|---|
| **Requirement** | Configure DLP policies for Entra-registered AI apps |
| **Doc URL** | https://learn.microsoft.com/purview/developer/use-the-api |
| **Mechanism** | PowerShell cmdlet `New-DlpComplianceRule` |
| **Limitations** | **Portal UI does NOT support creating DLP policies for Entra-registered applications.** Must use PowerShell. Collection policies must be configured via DSPM for AI one-click policies or `Set-FeatureConfiguration`. |
| **Decision** | Document as operational prerequisite. Include PowerShell commands in the deployment runbook. |

### 2.5 Azure AI Content Safety (Complementary)

| Field | Value |
|---|---|
| **Requirement** | Content moderation for harm categories (optional, complementary to Purview) |
| **Doc URL** | https://learn.microsoft.com/azure/ai-services/content-safety/overview |
| **Mechanism** | REST API: `POST <endpoint>/contentsafety/text:analyze?api-version=2024-09-01` |
| **NuGet Package** | `Azure.AI.ContentSafety` |
| **Auth Mode** | API Key or Managed Identity |
| **Status** | GA |
| **Limitations** | Evaluates harm categories (Hate, SelfHarm, Sexual, Violence), NOT organizational DLP policies. 10K char limit per request. |
| **Decision** | Not required for MVP. Can be added as an optional content safety layer alongside Purview. Design the interface to accommodate this later. |

---

## 3. Microsoft Entra ID

### 3.1 ASP.NET Core Authentication

| Field | Value |
|---|---|
| **Requirement** | Authenticate admin users and validate API tokens |
| **Doc URL** | https://learn.microsoft.com/entra/msidweb/getting-started/quickstart-webapi |
| **NuGet Packages** | `Microsoft.Identity.Web`, `Microsoft.Identity.Web.UI` |
| **Status** | GA |
| **Decision** | Use `AddMicrosoftIdentityWebApi` for API, `AddMicrosoftIdentityWebApp` for Blazor admin UI. |

### 3.2 Application Roles

| Field | Value |
|---|---|
| **Requirement** | Define and enforce gateway roles (Administrator, Operator, Auditor, SupportReader, ExternalAgent) |
| **Doc URL** | https://learn.microsoft.com/entra/identity-platform/howto-add-app-roles-in-apps |
| **Mechanism** | App manifest `appRoles` array, `[Authorize(Roles = "...")]` in ASP.NET Core |
| **Status** | GA |
| **Limitations** | Group-based role assignment requires Entra ID Premium. Roles appear in `roles` claim. |
| **Decision** | Define 5 app roles in manifest. Use `allowedMemberTypes: ["User"]` for admin roles, `["Application"]` for ExternalAgent. |

### 3.3 Workload Identity Federation

| Field | Value |
|---|---|
| **Requirement** | External agent authentication without stored secrets |
| **Doc URL** | https://learn.microsoft.com/entra/workload-id/workload-identity-federation |
| **Considerations** | https://learn.microsoft.com/entra/workload-id/workload-identity-federation-considerations |
| **Status** | GA |
| **Limitations** | **Max 20 federated identity credentials per app/managed identity.** RS256 tokens only. Case-sensitive matching. No wildcards. Concurrent updates to FICs on same managed identity cause 409 conflicts. |
| **Decision** | Support as optional auth method for external agents. Default to client credential flow with certificate. Document the 20-credential limit — may require separate app registrations per external agent for federation. |

### 3.4 Graph API for App Management

| Field | Value |
|---|---|
| **Requirement** | Programmatically create app registrations and service principals for external agents |
| **Doc URL (Create App)** | https://learn.microsoft.com/graph/api/application-post-applications |
| **Doc URL (Create SP)** | https://learn.microsoft.com/graph/api/serviceprincipal-post-serviceprincipals |
| **Doc URL (App Roles)** | https://learn.microsoft.com/graph/permissions-grant-via-msgraph |
| **NuGet Package** | `Microsoft.Graph` (v5.x) |
| **Status** | GA (v1.0) |
| **Decision** | Use `Application.ReadWrite.OwnedBy` for least-privilege. See permissions matrix below. |

### 3.5 Managed Identity with Azure Services

| Service | NuGet Package | RBAC Role | Doc URL |
|---|---|---|---|
| Key Vault | `Azure.Security.KeyVault.Secrets`, `.Certificates` | `Key Vault Secrets User`, `Key Vault Certificates Officer` | https://learn.microsoft.com/azure/key-vault/general/tutorial-net-create-vault-azure-web-app |
| Azure SQL | `Microsoft.Data.SqlClient` | SQL roles via `CREATE USER FROM EXTERNAL PROVIDER` | https://learn.microsoft.com/azure/azure-sql/database/azure-sql-dotnet-quickstart |
| Service Bus | `Azure.Messaging.ServiceBus` | `Azure Service Bus Data Sender`, `Data Receiver` | https://learn.microsoft.com/azure/service-bus-messaging/service-bus-managed-service-identity |

All GA. Use `Azure.Identity` with `DefaultAzureCredential` for all.

---

## 4. Permissions Matrix

### 4.1 Gateway Workload Identity (Backend Services)

| # | API Resource | Permission Name | Type | Admin Consent | Feature | When Required | Justification |
|---|---|---|---|---|---|---|---|
| 1 | Microsoft Graph | `Application.ReadWrite.OwnedBy` | Application | Yes | External agent app registration | Provisioning | Least-privilege: only manages apps the gateway owns |
| 2 | Microsoft Graph | `Application.Read.All` | Application | Yes | Service principal lookup | Runtime | Read-only lookup for identity validation |
| 3 | Microsoft Graph | `AppRoleAssignment.ReadWrite.All` | Application | Yes | Assign ExternalAgent role to new apps | Provisioning | Required for programmatic role assignment |
| 4 | Microsoft Graph | `AgentIdentityBlueprint.ReadWrite.All` | Application | Yes | Blueprint CRUD | Provisioning | Create/manage agent blueprints (beta permission) |
| 5 | Microsoft Graph | `AgentIdentityBlueprintPrincipal.Create` | Application | Yes | Create blueprint SP | Provisioning | Required since gateway can't use managerApplications (beta permission) |
| 6 | Microsoft Graph | `AgentIdentity.Read.All` | Application | Yes | Identity lookup, idempotency | Provisioning + Runtime | Check existing identities (beta permission) |
| 7 | Microsoft Graph | `AgentRegistration.ReadWrite.All` | Application | Yes | Agent 365 registry | Provisioning | Register/update/delete agents in registry |
| 8 | Agent 365 | `Agent365.Observability.OtelWrite` | Application | Yes | Telemetry export | Runtime | Write observability data on audience `9b975845-388f-4429-889e-eab1ef63949c` |
| 9 | Microsoft Graph | `Content.Process.User` | Application | Yes | Purview evaluation | Runtime | Evaluate content against DLP policies |
| 10 | Microsoft Graph | `ProtectionScopes.Compute.User` | Application | Yes | Purview scope check | Runtime | Determine applicable policies per user |
| 11 | Microsoft Graph | `ContentActivity.Write` | Application | Yes | Purview audit | Runtime | Submit audit records |
| 12 | Microsoft Graph | `User.Read.All` | Application | Yes | User validation | Runtime | Validate user context for Purview calls |

### 4.2 Gateway Admin UI (Delegated)

| # | API Resource | Permission Name | Type | Admin Consent | Feature |
|---|---|---|---|---|---|
| 1 | Gateway API | `access_as_admin` | Delegated | No | Admin access to gateway API |
| 2 | Microsoft Graph | `User.Read` | Delegated | No | Signed-in user profile |

### 4.3 External Agent Clients (Application)

| # | API Resource | Permission Name | Type | Admin Consent | Feature |
|---|---|---|---|---|---|
| 1 | Gateway API | `ExternalAgent` | Application (App Role) | Yes | Data-plane access |

### 4.4 Entra Roles Required

| Role | Who | Purpose | Doc URL |
|---|---|---|---|
| Agent ID Developer | Gateway managed identity | Blueprint setup (minimum CLI role) | https://learn.microsoft.com/microsoft-agent-365/developer/registration |
| Agent ID Administrator | Gateway admin (for S2S grants) | Higher-privilege agent operations | Same |
| Global Administrator | Tenant admin (one-time) | OAuth2 permission grants during setup | Same |
| Key Vault Secrets User | Gateway managed identity | Read secrets at runtime | https://learn.microsoft.com/azure/key-vault/general/secure-key-vault |
| Key Vault Certificates Officer | Gateway managed identity | Manage certificates for agent credentials | Same |
| Azure Service Bus Data Sender | Gateway API managed identity | Send messages to queues | https://learn.microsoft.com/azure/service-bus-messaging/service-bus-managed-service-identity |
| Azure Service Bus Data Receiver | Gateway worker managed identity | Receive messages from queues | Same |

---

## 5. Preview Dependencies

| Capability | API Version | Impact | Mitigation |
|---|---|---|---|
| Agent Registration API | Graph beta | Core provisioning feature | Feature flag + CLI fallback |
| `AgentIdentityBlueprint.*` permissions | Beta (not in Entra admin center) | Must configure via Graph API directly | Script in deployment runbook |
| `AgentIdentityBlueprintPrincipal.Create` | Beta | Required for blueprint SP creation | No alternative — accept preview dependency |
| `AgentIdentity.Read.All` | Beta | Required for idempotency checks | Accept preview dependency |
| `AgentIdentity.DeleteRestore.All` | Beta | Cleanup/deletion operations | Make deletion a manual step if permission unavailable |

---

## 6. Unsupported Capabilities

| Capability | Status | Impact | Gateway Decision |
|---|---|---|---|
| Programmatic agent instance creation | No REST API exists | Cannot fully automate instance lifecycle | Implement `AwaitingAdminApproval` status. Provide instructions for admin to approve in M365 admin center. |
| Gateway as managerApplication | First-party apps only | Cannot use lower-privilege identity creation | Use `AgentIdentityBlueprintPrincipal.ReadWrite.All` (higher privilege) |
| Purview DLP policy creation via API | PowerShell only | Operational prerequisite, not automatable via gateway | Document in deployment runbook with exact PowerShell commands |
| Purview data retrieval | No read APIs | Cannot show Purview analytics in gateway UI | Gateway stores only decision metadata (allow/block/audit). Link to Purview portal for detailed reports. |
| Purview without user context | Not supported | Every `processContent` call needs a real user ID | External agents MUST provide `tenantUserObjectId`. Gateway validates it exists. Cannot fabricate application-only flow. |
| MCP server registration via API | CLI-only | Cannot programmatically register MCP servers | Out of scope for gateway MVP. Document limitation. |

---

## 7. Assumptions Requiring Validation

| # | Assumption | Risk | Validation Method |
|---|---|---|---|
| 1 | Beta Agent Registration API will reach GA | Medium | Monitor https://learn.microsoft.com/graph/versioning-and-support |
| 2 | `AgentIdentityBlueprint.*` permissions will become visible in Entra admin center | Low | Currently requires Graph API direct configuration |
| 3 | `processContent` supports application permissions with `/users/{userId}` path | Low (documented) | Validate in dev environment with test user |
| 4 | OTLP endpoint accepts S2S auth from a gateway acting on behalf of external agents | Medium | Validate that telemetry is correctly attributed per-agent |
| 5 | External agents can reliably provide `tenantUserObjectId` for Purview evaluation | Medium | Design requires this — document as integration contract |
| 6 | Workload identity federation 20-credential limit is sufficient | Medium | If >20 external agents use federation, need separate app registrations |
| 7 | `Agent365.Observability.OtelWrite` permission is available for tenant grant | Low | Validate during Entra setup |

---

## 8. NuGet Package Reference

| Package | Purpose | Status |
|---|---|---|
| `Microsoft.Identity.Web` | Entra auth for ASP.NET Core | GA |
| `Microsoft.Identity.Web.UI` | Sign-in/sign-out UI | GA |
| `Microsoft.Graph` | Graph API client (v5.x) | GA |
| `Azure.Identity` | DefaultAzureCredential / managed identity | GA |
| `Azure.Security.KeyVault.Secrets` | Key Vault secrets | GA |
| `Azure.Security.KeyVault.Certificates` | Key Vault certificates | GA |
| `Azure.Messaging.ServiceBus` | Service Bus client | GA |
| `Microsoft.Data.SqlClient` | Azure SQL with Entra auth | GA |
| `Microsoft.EntityFrameworkCore.SqlServer` | EF Core SQL Server provider | GA |
| `Microsoft.Agents.A365.Observability` | Agent 365 observability SDK | GA |
| `Microsoft.Agents.A365.Observability.Runtime` | Observability runtime | GA |
| `Microsoft.Agents.A365.Observability.Hosting` | Observability hosting integration | GA |
| `Microsoft.FluentUI.AspNetCore.Components` | Fluent UI for Blazor | GA |
| `OpenTelemetry` | Telemetry instrumentation | GA |
| `OpenTelemetry.Extensions.Hosting` | OTel host integration | GA |
| `OpenTelemetry.Exporter.OpenTelemetryProtocol` | OTLP exporter | GA |
| `Azure.Monitor.OpenTelemetry.Exporter` | Azure Monitor OTel exporter | GA |

---

## 9. Architecture Decision Records (Phase 1)

### ADR-001: Agent Registration API Preview Dependency

**Context:** The Agent Registration API (`/beta/copilot/agentRegistrations`) is the only REST API for registering agents in the Agent 365 registry. It is explicitly marked as beta and not supported for production.

**Decision:** Use the beta API behind a feature flag with CLI-based fallback. The gateway provisioning worker will:
1. First attempt registration via Graph API (beta).
2. If the feature flag is disabled or the API fails, queue for CLI-based registration.
3. Label the dependency as preview in all documentation and UI.

**Consequences:** Production deployments should validate beta API stability in their tenant before enabling. CLI fallback requires interactive authentication or a pre-authenticated token cache.

### ADR-002: managerApplications Constraint

**Context:** The `managerApplications` property on agent blueprints only accepts Microsoft first-party application IDs. The gateway cannot designate itself as a manager.

**Decision:** Accept higher-privilege permissions (`AgentIdentityBlueprintPrincipal.ReadWrite.All`) instead of the lower-privilege `AgentIdentity.CreateAsManager` path.

**Consequences:** Gateway workload identity requires broader permissions than ideal. Document this constraint and the Microsoft platform limitation clearly.

### ADR-003: Purview User Context Requirement

**Context:** All Purview `processContent` calls require a valid Entra user ID. There is no application-only anonymous evaluation mode.

**Decision:** External agents MUST provide a `tenantUserObjectId` in the AI interaction payload. The gateway validates the user exists via `User.Read.All` before calling Purview. If no user context is provided, Purview evaluation is skipped and the interaction is logged as `PurviewSkipped_NoUserContext`.

**Consequences:** External agents that cannot provide user context will not benefit from Purview DLP enforcement. This is a documented Microsoft platform requirement, not a gateway limitation.

### ADR-004: Instance Provisioning Manual Step

**Context:** Agent instance creation requires admin approval through M365 admin center or Teams. No REST API exists for programmatic instance provisioning.

**Decision:** Gateway provisioning creates the blueprint and registers the agent. Instance creation is a manual admin step. The gateway introduces an `AwaitingAdminApproval` provisioning substatus and provides instructions in the admin UI.

**Consequences:** Full end-to-end automation is not possible. Gateway reconciliation job checks for instance creation status.

---

## Phase 1 Completion Checklist

- [x] Documentation matrix created (this document)
- [x] Supported capabilities identified
- [x] Unsupported/unclear capabilities documented (Section 6)
- [x] Preview dependencies labeled (Section 5)
- [x] Exact permissions and roles matrix (Section 4)
- [x] Assumptions requiring validation listed (Section 7)
- [x] NuGet packages validated (Section 8)
- [x] Architecture decision records for critical constraints (Section 9)

## Open Issues for Phase 2

1. **CLI worker design:** How to orchestrate non-interactive CLI execution in a background worker
2. **Observability attribution:** Validate that S2S telemetry is correctly attributed per external agent
3. **Purview user context flow:** Design the interaction contract for external agents providing user IDs
4. **Provisioning state machine:** Design states incorporating `AwaitingAdminApproval`
5. **Hosting decision:** Container Apps vs App Service — finalize based on CLI worker requirements

## Microsoft Documentation Citations

All URLs in this document are from official Microsoft Learn documentation accessed on 2026-08-23. Key documentation families used:

- Agent 365 Developer: https://learn.microsoft.com/microsoft-agent-365/developer/
- Entra Agent ID: https://learn.microsoft.com/graph/api/resources/agentid-platform-overview
- Agent Registration API: https://learn.microsoft.com/microsoft-365/copilot/extensibility/api/admin-settings/agent-registration/overview
- Purview Developer: https://learn.microsoft.com/purview/developer/secure-ai-with-purview
- Purview API Tutorial: https://learn.microsoft.com/purview/developer/use-the-api
- Graph Permissions: https://learn.microsoft.com/graph/permissions-reference
- Entra Identity Platform: https://learn.microsoft.com/entra/identity-platform/
- Microsoft Identity Web: https://learn.microsoft.com/entra/msidweb/getting-started/quickstart-webapi
