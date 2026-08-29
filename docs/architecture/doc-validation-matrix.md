# Phase 1: Documentation Validation Matrix

## Executive Summary

This document validates every Microsoft API, SDK, CLI command, permission, and capability required by the A365 Custom Gateway against official Microsoft Learn documentation. The original research was conducted on 2026-08-23. Agent ID, Agent 365 Registry create/permissions, blueprint creation, Purview mixed execution modes, and clean-subscription bootstrap dependencies were revalidated against current Microsoft Learn pages through **2026-08-29**. The N:N correction changes the Gateway-owned ingress model, not the cited Microsoft outbound identity contract.

## Implementation Boundary

Documentation support is not deployment evidence. Local source implements workflow
v3. The current broad Release gate passes 1,109/1,109 tests and the solution build
has zero warnings/errors. Development continuous mode has Active registrations for
both create-new and reuse-existing blueprint paths. Both are Available as
`A365CustomGateway` agents in Microsoft 365 Admin Center; bound ingress returned
HTTP 202 and Agent 365 OTLP accepted sanitized exports. Blueprint-scoped Purview
Enforce is live-proven: benign content is audited and a synthetic sensitive
`uploadText` is blocked before observability enqueue. `downloadText` is offline and
the adapter honors each returned execution mode.
Safe identifiers, exact revisions/digests, and remaining external verification gaps
remain centralized in
[`docs/implementation-status.md`](../implementation-status.md) and the deployment
checkpoint.

The last independently captured live typed catalog reported 12 rows: 7 compatible/
selectable and 5 incompatible. A later user-run create-new flow was reported
successful, so these are point-in-time counts rather than a current inventory. The
v3 queue is `0/0/9`, retained v2 is `0/0/3`, and historical v1 is `0/0/2` at the
last independently captured queue checkpoint.

Three bounded workflow-v2 canaries are retained separately with zero active, zero
scheduled, and three v2 DLQ messages. The first failed GET-only at
`ResolveBlueprint` for an incompatible blueprint. The second selected a compatible
blueprint, received HTTP 201 from one FIC POST, and failed closed when the immediate
list read was stale; later read-only reconciliation proved exactly one matching FIC.
Neither operation created a child Agent ID, Agent 365 role assignment, Registry
record, or telemetry mapping. The third GET-reused the reconciled FIC, created and
verified a child Agent ID, assigned and verified OtelWrite, then received HTTP 500
from the documented Registry POST without a durable ID. Its outcome remains unknown
and it is not a successful canary. The three redacted failure artifacts are tracked at
`docs/operations/evidence/canary-failure-20260825.json` and
`docs/operations/evidence/canary-federation-failure-20260825.json`, and
`docs/operations/evidence/canary-registry-failure-20260826.json`.
After MFA and explicit Admin Center Refresh, exact display-name and child-ID searches
each returned 0 of 341 agents. That portal result is not an API guarantee that the
HTTP 500 create had no backend effect; no retry is safe.

The four additive SQL prepare scripts are deployed; SQL finalization remains
unapplied. The deployed API/worker enforce one-POST-maximum and bounded GET-only
post-mutation reconciliation plus a server-enforced admission expiry.
Microsoft-resource deletion and standalone reconciliation remain unsupported. See
[`docs/implementation-status.md`](../implementation-status.md). No row in this matrix
means the deployed Gateway has successfully executed the documented Microsoft
operation.

Workflow-v3 local source removes Registry HTTP from the worker. After stage 4 the
worker waits at 71%. The API accepts a user-only administrator completion action,
exchanges the signed-in assertion through OBO for the exact two delegated Registry
scopes, persists a creator-bound planned ID, and sends at most one CLI-compatible
create POST containing that `id` and the reviewed preview-provider
`managedByAppId`. HTTP 201 persists the safe returned ID immediately (using the
planned ID only when a successful response omits one) without requiring immediate
exact GET. Unknown outcomes permit only exact planned-ID GET recovery. Accepted
completion reaches 85% and emits only final worker verification.

### Key Findings

1. **Agent identity blueprints, blueprint principals, and agent identities have dedicated Microsoft Graph v1.0 create/read methods.** Standard Agent ID creation is programmatic and doesn't require per-agent administrator approval.
2. **Blueprints are reusable typed Agent ID resources.** A normal pre-existing Entra
   app registration or the Gateway API application cannot be converted in place or
   substituted as a blueprint; migration creates new Agent ID resources.
3. **Autonomous Agent Identity authentication is a two-stage token exchange.** The
   Gateway worker credential authenticates the blueprint with
   `fmi_path=<agent-identity-client-id>`; the resulting T1 assertion is exchanged for
   an Agent Identity token for Agent 365 observability. Credential/FIC metadata alone
   is not a token proof.
4. **The public direct Agent Registry API remains beta/preview** (`/beta/copilot/agentRegistrations`) and explicitly isn't supported for production applications.
5. **`managerApplications` accepts only Microsoft first-party application IDs.** The Gateway cannot designate itself. For this development tenant/provider, the required value was independently correlated from installed A365 CLI `1.1.214+90c444832f` and read-only tenant inventory to verified Microsoft 365 App Catalog Services. Treat it as tenant/provider input, not a universal constant. This platform-acceptance requirement is separate from the blueprint principal's automatic `AgentIdentity.CreateAsManager` permission.
6. **Agent 365 CLI uses delegated, signed-in-user authentication.** Supplying `--agent-name` or `--tenant-id` doesn't turn it into a managed-identity daemon, and Microsoft doesn't document injecting a worker managed-identity token into the CLI cache.
7. **Tenant approval for an optional Teams/AI-teammate instance remains separate.**
   Workflow v3 nevertheless requires a signed-in Gateway administrator to complete
   each Registry boundary through delegated OBO; the exact Registry scopes also need
   one-time tenant admin consent on the Gateway API app.
8. **Purview `processContent` API is GA (v1.0)** — supports both inline evaluation (block/allow) and offline audit. User context is mandatory.
9. **Purview DLP policies for custom apps must be created via PowerShell** — portal UI does not support this.
10. **No Purview APIs exist to read data out** — APIs are input-only.
11. **Observability has a documented OTLP endpoint** — telemetry export via `agent365.svc.cloud.microsoft` with `Agent365.Observability.OtelWrite` permission.

### Decision Impact

| Gateway Feature | Status | Decision |
|---|---|---|
| Standard Agent ID provisioning | Microsoft Graph v1.0 | Select or create a reusable typed blueprint, ensure its principal, configure the Gateway-worker FIC, create the child Agent ID, assign Agent 365 access, and verify by persisted identifiers; ordinary apps are not blueprints; standalone reconciliation remains unsupported; no per-agent approval |
| Agent 365 registry registration | Public direct API is beta | Use only behind an explicit preview provider gate; don't silently fall back to CLI after a failed create |
| Production registration provider | Requires an explicit supported-path decision | Prefer a documented SDK/CLI path where compatible; don't invent the CLI's AgentX V2 transport contract |
| Optional Teams/AI-teammate instance | Administrator-mediated after publishing | Model separately; use an approval state only after a real instance request exists |
| Blueprint management | Microsoft Graph v1.0 | Use the dedicated v1.0 methods and preserve the route-specific `id` and `appId` fields without requiring their values to differ |
| Observability export to Agent 365 | GA | Use OTLP endpoint with documented SDK |
| Purview inline evaluation | GA | Use `processContent` with `evaluateInline` mode |
| Purview audit logging | GA | Use `contentActivities` API |
| Gateway ingress authentication | Gateway-owned API-key scheme | Issue a unique key per registration, store only a salted hash, resolve it to one registration, and cross-check `externalAgentId`. This is not a Microsoft API and requires no external managed identity. |
| Gateway data-plane idempotency | Gateway-owned scoped record plus SQL application lock | Resolve the caller registration first, canonical-hash the typed request, then acquire an exclusive transaction-owned SQL application lock for registration + normalized endpoint + normalized UUIDv4 key before replay lookup. Hold it through all side effects and commit; same hash replays and different hash fails 409 before effects. One-time secret responses are never cached. The implementation and prepare script are deployed in development and focused races pass; real SQL Server multi-replica/staging stress remains required. [`sp_getapplock`](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-getapplock-transact-sql) |
| Gateway ingress rate limiting | Gateway-owned SQL fixed-window limiter | After Gateway-key authorization, atomically enforce database-UTC one-minute buckets for credential, authenticated registration, and global scopes. Return safe 429 Problem Details and limit/reset headers; dependency failures fail closed. The InMemory fallback is test-only. `20260825_ingress_rate_limit_buckets.sql` and the limiter are deployed in development; multi-replica load/security proof remains open. |
| Encrypted interaction-content storage | Azure Blob Storage private endpoint | Use the `blob` target subresource and `privatelink.blob.core.windows.net` private DNS zone linked to the Gateway VNet. Keep the application on the ordinary Blob endpoint, disable Storage public network access, and let VNet DNS route it to the private endpoint. |
| Provisioning same-job execution | Gateway-owned SQL session application lock | Acquire an exclusive session-owned `sp_getapplock` keyed by job ID on a dedicated connection before job execution and hold it through the stage attempt. The lock is implemented and deployed in development and its local tests pass; retain provider idempotency and multi-replica/failover stress gates. |
| Agent 365 outbound authentication | Entra Agent ID two-stage autonomous flow | Workflow final verification uses the Gateway-worker FIC and mapped `fmi_path` to acquire and validate the child Agent ID's Agent 365 observability token. |
| Legacy ordinary Entra app management | GA, but not workflow v3 | `Application.ReadWrite.OwnedBy` remains a validated generic capability, not a v3 provisioning permission |

---

## 1. Microsoft Agent 365

### 1.1 Blueprint Management

| Field | Value |
|---|---|
| **Requirement** | Create and manage agent identity blueprints |
| **Doc URL** | https://learn.microsoft.com/graph/api/agentidentityblueprint-post?view=graph-rest-1.0 |
| **List URL** | https://learn.microsoft.com/graph/api/agentidentityblueprint-list?view=graph-rest-1.0 |
| **Workflow Guide** | https://learn.microsoft.com/entra/agent-id/create-blueprint |
| **Mechanism** | Microsoft Graph v1.0 REST API |
| **Endpoints** | `POST /v1.0/applications/microsoft.graph.agentIdentityBlueprint` (Create) |
| | `GET /v1.0/applications/microsoft.graph.agentIdentityBlueprint` (List typed blueprints; default/max page 100, follow validated `@odata.nextLink`) |
| | `GET /v1.0/applications/{id}/microsoft.graph.agentIdentityBlueprint` (Get) |
| | `PATCH /v1.0/applications/{id}/microsoft.graph.agentIdentityBlueprint` (Update) |
| | `PATCH /v1.0/applications(uniqueName='{name}')/microsoft.graph.agentIdentityBlueprint` (Upsert, with `Prefer: create-if-missing`) |
| **Auth Mode** | Application or Delegated |
| **Create Permission** | `AgentIdentityBlueprint.Create` (least privileged) |
| **Additional Permissions** | `AgentIdentityBlueprint.AddRemoveCreds.All` for a federated identity credential; `AgentIdentityBlueprint.UpdateAuthProperties.All` only when configuring an identifier URI/OAuth scope |
| **Admin Consent** | Yes |
| **Status** | Dedicated Microsoft Graph **v1.0** method. Current method and permissions-reference pages publish both delegated and application permissions. Treat tenant/portal availability as a deployment preflight instead of labeling the method beta from older CLI text. |
| **Requirements** | `displayName` and at least one sponsor are required; an owner is recommended. The response contains named `id` (application object ID) and `appId` (application/client ID) properties. Microsoft documentation does not impose an inequality invariant. |
| **Limitations** | `managerApplications` accepts only Microsoft first-party app IDs and is limited to 10 entries. This doesn't prevent creating a blueprint principal through its documented v1.0 method. |
| **Historical development evidence** | An earlier read-only 2026-08-25 inventory returned 11 typed blueprints and all 11 had the same GUID in `id` and `appId`. Equality is therefore a valid provider response, not a malformed resource. The later 12-row compatibility catalog does not extend that equality observation to the added row. |
| **Reuse boundary** | A blueprint is a typed Agent ID resource that can create multiple Agent Identities. Microsoft documents migration from ordinary apps as creating a blueprint and Agent Identity alongside the old identity; there is no in-place conversion. The Gateway API application remains a resource API and cannot be selected as a blueprint. See https://learn.microsoft.com/entra/agent-id/agent-blueprint and https://learn.microsoft.com/entra/agent-id/migrate-custom-app-registrations-to-agent-id. |
| **Decision** | Use Graph v1.0 directly, expose a Gateway-owned Administrator-only typed catalog for the registration dropdown, persist both identifiers immediately, and independently verify the typed resource before completing the step. The API identity needs `AgentIdentityBlueprint.Read.All`; signed-in user privilege is not a substitute. Workflow v3 accepts `UseExisting` or `CreateNew`; it configures the Gateway-worker FIC with `AgentIdentityBlueprint.AddRemoveCreds.All` but does not configure an incoming OAuth scope. |

### 1.2 Agent Registration

| Field | Value |
|---|---|
| **Requirement** | Register agents in the Agent 365 registry |
| **Doc URL** | https://learn.microsoft.com/microsoft-365/copilot/extensibility/api/admin-settings/agent-registration/agentregistration-create |
| **Overview** | https://learn.microsoft.com/microsoft-365/copilot/extensibility/api/admin-settings/agent-registration/overview |
| **Mechanism** | Microsoft Graph **beta** REST API |
| **Endpoints** | `POST /beta/copilot/agentRegistrations` (Create) |
| | `GET /beta/copilot/agentRegistrations/{id}` (Get) |
| | `PATCH /beta/copilot/agentRegistrations/{id}` (Update) |
| | `DELETE /beta/copilot/agentRegistrations/{id}` (Delete) |
| **Auth Mode** | Application or Delegated |
| **Create Permission** | `AgentRegistration.ReadWrite.All` |
| **Known-ID Read Permission** | `AgentRegistration.Read.All` for `GET /beta/copilot/agentRegistrations/{id}` |
| **Admin Consent** | Yes |
| **Status** | **PREVIEW/BETA — "Use in production applications is not supported"** |
| **Limitations** | Beta, Global cloud only, and unsupported for production. Required properties include `displayName`, `createdBy`, `sourceCreatedDateTime`, and `sourceLastModifiedDateTime`. Public Learn supports application and delegated auth, defines `sourceAgentId` as the source-system identifier, and documents known-ID GET but no list/search by source ID. The historical v2 app-only custom-manager payload remains unresolved. |
| **Decision** | Workflow v3 uses the API's signed-in administrator OBO action with delegated `AgentRegistration.ReadWrite.All` and `AgentRegistration.Read.All`. Retain the Gateway external ID as `sourceAgentId`; use stored owner IDs and the signed-in `oid` as `createdBy`; persist a creator-bound planned `id`; send the reviewed preview-provider `managedByAppId`; persist the safe returned ID immediately, falling back to the planned ID only when a successful response omits one; reconcile unknown outcomes only by exact planned-ID GET. Never use app-only/CLI process fallback or send a second POST after an unknown outcome. Production support remains unclaimed. |

### 1.3 Agent Identity Blueprint Principal

| Field | Value |
|---|---|
| **Requirement** | Create the service principal associated with an agent identity blueprint |
| **Create Doc URL** | https://learn.microsoft.com/graph/api/agentidentityblueprintprincipal-post?view=graph-rest-1.0 |
| **Get Doc URL** | https://learn.microsoft.com/graph/api/agentidentityblueprintprincipal-get?view=graph-rest-1.0 |
| **Mechanism** | Microsoft Graph v1.0 REST API |
| **Create Endpoint** | `POST /v1.0/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal` with the blueprint `appId` |
| **Get Endpoint** | `GET /v1.0/servicePrincipals/{id}/microsoft.graph.agentIdentityBlueprintPrincipal` |
| **Auth Mode** | Application or Delegated |
| **Create Permission** | `AgentIdentityBlueprintPrincipal.Create` (least privileged) |
| **Read Permission** | The typed GET documents `AgentIdentityBlueprintPrincipal.Read.All` as least privileged and `Application.Read.All` as an accepted higher application permission. The current eight-role worker allowlist already requires `Application.Read.All` for downstream resource and app-role resolution, so no additional read role is required. |
| **Admin Consent** | Yes |
| **Status** | Dedicated Microsoft Graph **v1.0** method |
| **Behavior** | A blueprint principal is automatically assigned `AgentIdentity.CreateAsManager`, which cannot be revoked, and is limited to 250 agent identity creations. |
| **Decision** | Use the dedicated typed routes for both creation and verification, and persist the returned service-principal object ID separately. Keep `Application.Read.All` in the current allowlist; don't substitute a base service-principal route or require `AgentIdentityBlueprintPrincipal.ReadWrite.All` merely because the Gateway can't be a `managerApplication`. |

### 1.4 Agent Identity

| Field | Value |
|---|---|
| **Requirement** | Create a distinct Entra Agent ID for one agent from a blueprint |
| **Doc URL** | https://learn.microsoft.com/graph/api/agentidentity-post?view=graph-rest-1.0 |
| **Identity Model** | https://learn.microsoft.com/microsoft-agent-365/developer/identity |
| **Mechanism** | Microsoft Graph v1.0 REST API |
| **Endpoint** | `POST /v1.0/servicePrincipals/microsoft.graph.agentIdentity` |
| **Required Body** | `displayName`, `agentIdentityBlueprintId` (the blueprint application/client ID, `appId`), and at least one valid sponsor reference |
| **Auth Mode** | Application or Delegated |
| **Create Permission** | `AgentIdentity.Create.All`; alternatively call as the blueprint principal using its automatic `AgentIdentity.CreateAsManager` permission |
| **Read Permission** | `AgentIdentity.Read.All` for reconciliation/verification |
| **Admin Consent** | Yes when the Gateway workload identity is granted application permissions; the blueprint principal's manager permission is assigned automatically |
| **Status** | Dedicated Microsoft Graph **v1.0** method. An older Microsoft how-to still contains beta sample URLs; use the newer dedicated method page as the contract and retain the discrepancy in test/preflight notes. |
| **Identity semantics** | Current Microsoft Agent 365 identity documentation states the Agent ID object ID and application/client ID are the same GUID. Blueprint `id` and `appId` remain separately named Graph fields, but their values may also coincide; no inequality requirement is documented. |
| **Decision** | Add an explicit `CreateAgentIdentity` step, send the persisted value from the blueprint `appId` field, persist the returned Agent Identity ID under the contract's explicit object/client field names, require those child fields to be equal, verify `agentIdentityBlueprintId` equals the blueprint `appId`, and don't model standard creation as awaiting per-agent approval. Never infer the route field merely because the blueprint `id` and `appId` values happen to match. |

### 1.5 Autonomous Agent Identity Authentication for Agent 365 Export

| Field | Value |
|---|---|
| **Requirement** | Obtain an Agent 365 observability token for the child Agent ID without a credential on the child identity |
| **Doc URL** | https://learn.microsoft.com/entra/agent-id/autonomous-agent-authentication-authorization-flow |
| **Credential model** | Credentials live on the reusable blueprint. Workflow v3 creates or reuses one deterministic managed-identity FIC for the trusted Gateway worker with **exactly one** audience, `api://AzureADTokenExchange`; the child Agent ID itself has no secret/certificate/FIC. |
| **Stage 1** | Request a blueprint token with blueprint `client_id`, `scope=api://AzureADTokenExchange/.default`, `grant_type=client_credentials`, the managed-identity assertion, and `fmi_path=<agent-identity-client-id>`. |
| **Stage 2** | Exchange T1 with Agent Identity `client_id`, `grant_type=client_credentials`, JWT-bearer `client_assertion_type`, and `client_assertion=<T1>` for Agent 365 observability scope `9b975845-388f-4429-889e-eab1ef63949c/.default`. |
| **Resource authorization** | Assign Agent 365 `Agent365.Observability.OtelWrite` to the child Agent Identity service-principal object ID on resource app `9b975845-388f-4429-889e-eab1ef63949c`. The Graph assignment method requires `AppRoleAssignment.ReadWrite.All` **and** `Application.Read.All`: https://learn.microsoft.com/graph/api/serviceprincipal-post-approleassignments?view=graph-rest-1.0. Do not assign Gateway `ExternalAgent` for normal N:N ingress. |
| **Implemented workflow-v3 boundary** | After the API has persisted delegated exact-ID Registry evidence, `VerifyAgent365Connection` re-reads the blueprint, principal, Gateway FIC, child Agent ID, and observability assignment, then uses the Gateway FIC to validate the mapped child Agent ID's Agent 365 token and role. The worker makes no Registry HTTP call. The current live v3 canary has not reached this final stage. |
| **Gateway ingress boundary** | Ingress is Gateway-owned: a one-time per-registration API key is stored only as a salted hash and resolves the caller registration before the body ID is cross-checked. `GET /api/v1/agent-runtime/readiness` and data-plane posts use that key, not the autonomous token flow. Readiness proves only key validity/non-deleted binding and intentionally does not require `Active`; ingestion has a separate status gate. |
| **Aggregate readiness boundary** | Current official docs don't define a safe GA aggregate endpoint that proves FIC usability. Typed blueprint FIC listing is documented only on Graph beta; actual Agent 365 token issuance is authoritative for outbound readiness. See https://learn.microsoft.com/graph/api/federatedidentitycredential-list?view=graph-rest-beta. |

### 1.6 Optional Teams / AI-Teammate Instance

| Field | Value |
|---|---|
| **Requirement** | Give a published agent a Teams/Microsoft 365 instance and, when needed, an agent user account |
| **Doc URL** | https://learn.microsoft.com/microsoft-agent-365/developer/create-instance |
| **Mechanism** | Publish the agent, configure its messaging endpoint in Teams Developer Portal, request an instance in Teams, and obtain tenant-admin approval in Microsoft 365 admin center |
| **Status** | Separate optional workflow. Agent user accounts are available only to tenants in the Frontier preview program and require appropriate Microsoft 365 licensing. |
| **Limitations** | No public server-side instance-create contract was validated for the Gateway. The current Gateway registration request doesn't contain a published package, messaging endpoint, instance request ID, or agent-user configuration. |
| **Decision** | Keep this flow outside standard Agent ID/registry provisioning. Enter an approval state only after a real instance request exists; use a distinct status such as `AwaitingInstanceApproval`. |

### 1.7 managerApplications

| Field | Value |
|---|---|
| **Requirement** | Configure and verify the Microsoft first-party manager applications required for Agent 365 blueprint acceptance |
| **Doc URL** | https://learn.microsoft.com/graph/api/resources/agentidentityblueprint?view=graph-rest-1.0#properties |
| **List URL** | https://learn.microsoft.com/graph/api/agentidentityblueprint-list?view=graph-rest-1.0 |
| **Agent 365 Setup Context** | https://learn.microsoft.com/microsoft-agent-365/developer/registration |
| **Mechanism** | Property on `agentIdentityBlueprint` resource |
| **Read behavior** | `managerApplications` isn't returned by default and supports `$select`; the typed v1.0 list supports `$select` and application authentication with `AgentIdentityBlueprint.Read.All`. |
| **Status** | GA (as a property) |
| **Limitations** | **Only Microsoft first-party application IDs can be designated as managers.** Third-party applications cannot be added. Max 10 entries. Not nullable. |
| **Decision** | **Gateway CANNOT add itself to `managerApplications`.** Create the blueprint principal with `AgentIdentityBlueprintPrincipal.Create`. For the current development tenant/provider, a read-only 2026-08-25 correlation of A365 CLI `1.1.214+90c444832f`, blueprint inventory, and the tenant service principal identifies verified Microsoft 365 App Catalog Services as the provider input. Pass it through reviewed configuration to both API and worker, record source/version/date, and revalidate for another tenant/provider version; never make it a universal hard-coded constant. The API catalog selects `managerApplications`, returns every typed blueprint with safe compatibility metadata, and treats an existing blueprint as compatible only when all configured provider IDs are present. It never returns the manager IDs. Registration rechecks compatibility before persistence/key issuance, and the worker verifies it again before provisioning. |

### 1.8 Agent 365 CLI

| Field | Value |
|---|---|
| **Requirement** | Explicit administrator-run CLI provisioning option |
| **Doc URL** | https://learn.microsoft.com/microsoft-agent-365/developer/agent-365-cli |
| **Reference** | https://learn.microsoft.com/microsoft-agent-365/developer/reference/cli/ |
| **NuGet Package** | `Microsoft.Agents.A365.DevTools.Cli` (dotnet tool) |
| **Install** | `dotnet tool install --global Microsoft.Agents.A365.DevTools.Cli` |
| **Key Commands** | `a365 setup all`, `a365 setup blueprint`, `a365 cleanup`, `a365 publish` |
| **Requires** | .NET 8.0+, Azure Contributor + Agent ID Developer roles |
| **Auth Mode** | Delegated public-client authentication by a signed-in user. The CLI documentation explicitly says not to configure application permissions for the CLI client. |
| **Status** | Documented supported developer tool. The cited current Learn pages don't establish a managed-identity daemon contract or an automatic production fallback. |
| **Standard Order** | Requirements → blueprint → permissions → Agent Identity → registration through the CLI's AgentX V2 API → configuration sync |
| **Limitations** | `--agent-name` and `--tenant-id` avoid some prompts but don't change authentication mode. Official CLI 1.1.214 at exact commit `90c4448` is delegated/AgentX-specific: it uses a client-generated Registry `id`, child Agent ID as source, a hard-coded AgentX manager, and documents CLI-ID 424. Those choices do not establish app-only payload semantics. |
| **Decision** | Use only as an explicit administrator-run/out-of-band provider unless Microsoft documents a service authentication mode. Do not inject a worker managed-identity token into its cache, copy its AgentX payload semantics, or silently invoke it after a beta-API failure. |

### 1.9 Observability

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
| **Decision** | Use Direct OTel integration (OTLP/HTTP) with the child Agent Identity's S2S token and `Agent365.Observability.OtelWrite`. The workflow assigns that role to each child Agent Identity; the worker/exporter identity is not the per-agent telemetry identity. For Entra child attribution, emit the child client ID as `gen_ai.agent.id` and the blueprint client ID as `microsoft.a365.agent.blueprint.id`; omit `gen_ai.agent.type` and `microsoft.a365.agent.platform.id`. Agent 365 export is enabled by default; an independently configured Azure Monitor mirror is optional and off by default. Both destinations receive sanitized telemetry. Gateway/platform diagnostics and Purview controls remain separate from these per-agent destinations. An OTLP HTTP 200 proves transport acceptance only; require independent delayed `CloudAppEvents` evidence before claiming downstream landing. |

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
| **Permission (least)** | `ProtectionScopes.Compute.User` (`fe696d63-5e1f-4515-8232-cccc316903c6`) |
| **Permission (higher)** | `ProtectionScopes.Compute.All` |
| **Admin Consent** | Yes |
| **Status** | **v1.0 GA** |
| **Limitations** | Not available in China (21Vianet). Personal Microsoft accounts not supported. Returns a collection of `policyUserScope` objects with `executionMode`: `evaluateInline` or `evaluateOffline`; it does not return a single scope ID. |
| **Decision** | Query policy for the selected reusable blueprint's `policyLocationApplication`, cache inline-capable results by Entra user object ID plus blueprint client ID for 30 minutes, and retain the response ETag. Children sharing a blueprint share policy scope while `aiAgentInfo` preserves child/blueprint attribution. Do not cache empty/offline-only scopes during distribution. Send the ETag to `processContent` and re-compute once when `protectionScopeState` returns `modified`. |

### 2.2 Process Content (Inline Policy Evaluation)

| Field | Value |
|---|---|
| **Requirement** | Evaluate prompts/responses against Purview DLP policies |
| **Doc URL** | https://learn.microsoft.com/graph/api/userdatasecurityandgovernance-processcontent |
| **Mechanism** | Microsoft Graph v1.0 REST API |
| **Endpoint** | `POST /users/{userId}/dataSecurityAndGovernance/processContent` |
| **Auth Mode** | Application or Delegated |
| **Permission (least)** | `Content.Process.User` (`24ceb246-ad29-4680-90b4-3e91ffad15eb`) |
| **Permission (higher)** | `Content.Process.All` |
| **Admin Consent** | Yes |
| **Status** | **v1.0 GA** |
| **Limitations** | **User context (Entra user ID) is mandatory** — no anonymous/service-account-only mode. When `executionMode` is `evaluateInline`, caller must block until API responds. Returns `policyActions` with `restrictAccess`/`block`. Also handles audit logging when called. Not available in China (21Vianet). |
| **Decision** | Use only for `Enforce`: send `processConversationMetadata` with raw text plus child Agent Identity/blueprint `aiAgentInfo`. Handle each activity according to its documented mode: wait for a 200 verdict for `evaluateInline`; submit `evaluateOffline` without requiring a synchronous body and accept 200/202/204. Block exact `restrictAccess:block`; fail closed on missing/unknown modes, processing errors, or dependency failure. `AuditOnly` uses content activities without raw content. **Critical: Gateway must receive a valid user Entra object ID from the external agent — it cannot fabricate this.** |

### 2.3 Content Activity (Audit Logging)

| Field | Value |
|---|---|
| **Requirement** | Submit AI interaction audit records to Purview |
| **Doc URL** | https://learn.microsoft.com/graph/api/activitiescontainer-post-contentactivities |
| **Mechanism** | Microsoft Graph v1.0 REST API |
| **Endpoint** | `POST /users/{userId}/dataSecurityAndGovernance/activities/contentActivities` |
| **Auth Mode** | Application or Delegated |
| **Permission** | `ContentActivity.Write` (`2932e07a-3c29-44e4-bb36-6d0fc176387f`) |
| **Admin Consent** | Yes |
| **Status** | **v1.0 GA** |
| **Limitations** | User context required. Input-only — no APIs to read data back out. Audit records appear in Activity Explorer as `ConnectedAIAppInteraction` record type. |
| **Decision** | Use synchronously for `AuditOnly`, one metadata-only activity for prompt upload and one for response download. Match the documented content-activity shape: omit both `content` and conversation `agents`. A failed submission rejects the interaction; no audit retry queue is implemented. Live development proof returned HTTP 201 for both activities. |

### 2.4 Purview Operational Requirements

| Field | Value |
|---|---|
| **Requirement** | Configure DLP policies for Entra-registered AI apps |
| **Doc URL** | https://learn.microsoft.com/purview/developer/use-the-api |
| **Mechanism** | PowerShell cmdlet `New-DlpComplianceRule` |
| **Limitations** | Tenant policy authoring and collection settings are external prerequisites. Microsoft now documents the `Application` enforcement plane; the older `Entra` plane is deprecated. Exact portal/PowerShell availability can change. |
| **Decision** | Use the reusable blueprint client ID as the protected application location and child/blueprint IDs as Enforce `aiAgentInfo`. This makes the blueprint the shared governance boundary and avoids one DLP policy per child. Development proves inline `uploadText` blocking plus offline `downloadText` submission with a synthetic Enforce canary. |

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
| **Requirement** | Authenticate blueprint-backed agents without stored secrets |
| **Doc URL** | https://learn.microsoft.com/entra/workload-id/workload-identity-federation |
| **Create FIC** | https://learn.microsoft.com/graph/api/federatedidentitycredential-post?view=graph-rest-1.0 |
| **Get FIC** | https://learn.microsoft.com/graph/api/federatedidentitycredential-get?view=graph-rest-1.0 |
| **Considerations** | https://learn.microsoft.com/entra/workload-id/workload-identity-federation-considerations |
| **Status** | GA |
| **Documented create/read behavior** | Graph create returns HTTP 201 and a `federatedIdentityCredential` object. Graph supports a later GET by the credential's ID or name. Microsoft requires the audiences collection to contain a single value and recommends `api://AzureADTokenExchange`. |
| **Documented consistency boundary** | Microsoft states that FIC changes take time to propagate and that token requests can fail for several minutes while caches hold older data; token acquisition should use retry. This is documentation of federation/token propagation, not a guarantee that a particular list read is immediately consistent. |
| **Limitations** | **Max 20 federated identity credentials per app/managed identity.** Exactly one audience. RS256 tokens only. Case-sensitive matching. No wildcards. Concurrent updates to FICs on the same managed identity cause 409 conflicts. |
| **Gateway decision/inference** | Workflow v3 configures one deterministic managed-identity FIC on each selected reusable Agent ID blueprint for the trusted Gateway worker. The child Agent ID has no credential of its own. Reusing the same Gateway FIC at blueprint scope avoids one FIC per registration. Each logical FIC creation emits at most one POST; after a 201 it preserves the returned ID and uses bounded, cancellation-aware GET-only reconciliation of ID, name, issuer, subject, and exactly one audience. Missing, duplicate, or mismatched reads fail closed without a second POST. This recovery schedule is a Gateway safety policy derived from the documented create/get and propagation behavior, not a Microsoft-prescribed retry sequence. |

### 3.4 Graph API for Ordinary App Management (Legacy/Future)

| Field | Value |
|---|---|
| **Requirement** | Programmatically create ordinary app registrations and service principals where a non-Agent-ID flow explicitly requires them |
| **Doc URL (Create App)** | https://learn.microsoft.com/graph/api/application-post-applications |
| **Doc URL (Create SP)** | https://learn.microsoft.com/graph/api/serviceprincipal-post-serviceprincipals |
| **Doc URL (App Roles)** | https://learn.microsoft.com/graph/permissions-grant-via-msgraph |
| **NuGet Package** | `Microsoft.Graph` (v5.x) |
| **Status** | GA (v1.0) |
| **Decision** | `Application.ReadWrite.OwnedBy` is the validated least-privilege option for an ordinary-app flow, but workflow v3 does not create an ordinary external-client app and does not request this permission. Ordinary apps cannot be reused as Agent ID blueprints. |

### 3.5 Managed Identity with Azure Services

| Service | NuGet Package | RBAC Role | Doc URL |
|---|---|---|---|
| Key Vault | `Azure.Security.KeyVault.Secrets`, `.Certificates` | `Key Vault Secrets User`, `Key Vault Certificates Officer` | https://learn.microsoft.com/azure/key-vault/general/tutorial-net-create-vault-azure-web-app |
| Azure SQL | `Microsoft.Data.SqlClient` | SQL roles via `CREATE USER FROM EXTERNAL PROVIDER` | https://learn.microsoft.com/azure/azure-sql/database/azure-sql-dotnet-quickstart |
| Service Bus | `Azure.Messaging.ServiceBus` | `Azure Service Bus Data Sender`, `Data Receiver` | https://learn.microsoft.com/azure/service-bus-messaging/service-bus-managed-service-identity |

All GA. Use `Azure.Identity` with `DefaultAzureCredential` for all.

---

## 4. Permissions Matrix

### 4.1 Gateway backend and delegated Registry boundaries

Workflow v3 requires exactly these eight Microsoft Graph application roles on the
worker managed identity:

1. `Application.Read.All`
2. `AppRoleAssignment.ReadWrite.All`
3. `AgentIdentityBlueprint.Create`
4. `AgentIdentityBlueprint.AddRemoveCreds.All`
5. `AgentIdentityBlueprintPrincipal.Create`
6. `AgentIdentityBlueprint.Read.All`
7. `AgentIdentity.Create.All`
8. `AgentIdentity.Read.All`

The deployed v2 worker had a ten-role set that also included both Registry roles.
That remains historical evidence, not the v3 target. V3 removes only those two
obsolete assignments. `Application.ReadWrite.OwnedBy` belonged to workflow v1 and is
not current. Re-observe assignments before every activation because identity
recreation or consent changes can invalidate the checkpoint.

The API managed identity is a separate permission boundary for the Administrator-
only typed blueprint catalog. It needs the single Graph application role
`AgentIdentityBlueprint.Read.All`. The API application separately requests delegated
`AgentRegistration.ReadWrite.All` and `AgentRegistration.Read.All`, has tenant-wide
admin consent for both, and uses one exact API-managed-identity FIC to make its OBO
confidential-client assertion. The worker additionally needs trusted deployment
configuration `Agent365__ProvisioningManagedIdentityPrincipalId` matching its Graph
token `oid`. None is inherited from the signed-in administrator's Gateway role.

The broader catalog below records validated future/conditional permissions as well as
the current set. A future row is not deployment authorization.

| # | API Resource | Permission Name | Type | Admin Consent | Feature | When Required | Justification |
|---|---|---|---|---|---|---|---|
| 1 | Microsoft Graph | `Application.ReadWrite.OwnedBy` | Application | Yes | Ordinary app registration | Legacy/future; **not workflow v3** | Least-privilege for an explicitly selected ordinary-app flow; it cannot create or convert an Agent ID blueprint |
| 2 | Microsoft Graph | `Application.Read.All` | Application | Yes | Service principal lookup | Runtime | Read-only lookup for identity validation |
| 3 | Microsoft Graph | `AppRoleAssignment.ReadWrite.All` | Application | Yes | Assign Agent 365 observability role to child Agent IDs | Provisioning | Required for programmatic role assignment |
| 4 | Microsoft Graph | `AgentIdentityBlueprint.Create` | Application | Yes | Create agent identity blueprint | Provisioning | Least-privileged documented create permission |
| 5 | Microsoft Graph | `AgentIdentityBlueprint.AddRemoveCreds.All` | Application | Yes | Configure blueprint FIC | Current workflow v3; v2 use verified in development | Create/verify the Gateway-worker FIC on the reusable blueprint |
| 6 | Microsoft Graph | `AgentIdentityBlueprint.UpdateAuthProperties.All` | Application | Yes | Configure identifier URI/OAuth scope | Future/conditional; **not current** | Required only for a future OBO/incoming-request blueprint configuration |
| 7 | Microsoft Graph | `AgentIdentityBlueprintPrincipal.Create` | Application | Yes | Create blueprint principal | Provisioning | Least-privileged documented principal-create permission |
| 8 | Microsoft Graph | `AgentIdentityBlueprint.Read.All` | Application | Yes | Blueprint verification | Provisioning + reconciliation | Verify a persisted blueprint without granting write-all |
| 9 | Microsoft Graph | `AgentIdentityBlueprintPrincipal.Read.All` | Application | Yes | Blueprint-principal verification | Future/conditional; **not current** | Current adapter uses the typed Blueprint Principal GET, which also accepts the already-required `Application.Read.All` application role |
| 10 | Microsoft Graph | `AgentIdentity.Create.All` | Application | Yes | Direct worker-created Agent Identity | Current workflow v3; v2 use verified in development | The worker creates each Agent Identity directly |
| 11 | Microsoft Graph | `AgentIdentity.Read.All` | Application | Yes | Agent Identity lookup | Provisioning + reconciliation | Verify the persisted Agent Identity and its blueprint relationship |
| 12 | Microsoft Graph | `AgentRegistration.Read.All` | Delegated | Yes | API OBO exact-ID Registry verification | Workflow-v3 Gateway API app; not worker | Required by `GET /beta/copilot/agentRegistrations/{id}`; no documented list or `sourceAgentId` search exists |
| 13 | Microsoft Graph | `AgentRegistration.ReadWrite.All` | Delegated | Yes | API OBO Registry create | Workflow-v3 Gateway API app; not worker | Required by `POST /beta/copilot/agentRegistrations`; the caller must pass the user-only completion policy |
| 14 | Agent 365 | `Agent365.Observability.OtelWrite` | Application | Yes | Per-agent telemetry export | Workflow assignment + runtime | Assign to each child Agent Identity on resource app `9b975845-388f-4429-889e-eab1ef63949c`; don't substitute the worker/exporter identity |
| 15 | Microsoft Graph | `Content.Process.User` | Application | Yes | Purview evaluation | Runtime | Evaluate content against DLP policies |
| 16 | Microsoft Graph | `ProtectionScopes.Compute.User` | Application | Yes | Purview scope check | Runtime | Determine applicable policies per user |
| 17 | Microsoft Graph | `ContentActivity.Write` | Application | Yes | Purview audit | Runtime | Submit audit records |
`AgentIdentity.CreateAsManager` isn't an application permission to grant to the Gateway workload identity in this design. Microsoft Entra assigns it automatically to the created blueprint principal. Broad read/write or delete/restore permissions aren't provisioning defaults; validate and approve them separately before claiming external reconciliation or deletion.

### 4.2 Gateway Admin UI (Delegated)

| # | API Resource | Permission Name | Type | Admin Consent | Feature |
|---|---|---|---|---|---|
| 1 | Gateway API | `access_as_admin` | Delegated | No | Admin access to gateway API |
| 2 | Microsoft Graph | `User.Read` | Delegated | No | Signed-in user profile |

### 4.3 Child Agent Identity and Gateway Ingress Authorization

| # | API Resource | Permission Name | Type | Admin Consent | Feature |
|---|---|---|---|---|---|
| 1 | Gateway API | Per-registration Gateway API key | Gateway-owned credential | No Microsoft consent | Salted hash binds readiness/data-plane calls to one stored registration; the clear key is returned only at issuance/rotation |
| 2 | Agent 365 (`9b975845-388f-4429-889e-eab1ef63949c`) | `Agent365.Observability.OtelWrite` | Application (App Role) | Yes | Assign to the child Agent Identity; its Agent 365 token authorizes sanitized OTLP export |

The legacy Gateway `ExternalAgent` app role remains part of historical workflow-v1
state and code paths. It is not assigned to new N:N child Agent IDs and is not the
current ingress authentication scheme.

### 4.4 Entra Roles Required

| Role | Who | Purpose | Doc URL |
|---|---|---|---|
| Privileged Role Administrator (or higher) | Tenant administrator | Grant Microsoft Graph application permissions to the Gateway workload identity | https://learn.microsoft.com/entra/agent-id/create-blueprint |
| Agent ID Developer | Signed-in administrator/developer | Delegated portal or CLI blueprint setup; not assigned to the managed identity as a substitute for application permissions | https://learn.microsoft.com/microsoft-agent-365/developer/registration |
| Agent ID Administrator / Application Administrator | Signed-in administrator | Documented handoff for higher-privilege or S2S grants when using CLI workflows | https://learn.microsoft.com/microsoft-agent-365/developer/reference/cli/setup |
| Global Administrator | Tenant administrator | OAuth2 permission grants/tenant-wide consent when the documented setup path requires them | Same |
| Key Vault Secrets User | Gateway managed identity | Read secrets at runtime | https://learn.microsoft.com/azure/key-vault/general/secure-key-vault |
| Key Vault Certificates Officer | Explicitly selected platform identity | Manage a separately approved platform certificate flow; workflow v3 Agent ID/OBO credentials use federated assertions instead | Same |
| Azure Service Bus Data Sender | Gateway API managed identity | Send messages to queues | https://learn.microsoft.com/azure/service-bus-messaging/service-bus-managed-service-identity |
| Azure Service Bus Data Receiver | Gateway worker managed identity | Receive messages from queues | Same |

---

## 5. Preview Dependencies

| Capability | API Version | Impact | Mitigation |
|---|---|---|---|
| Direct Agent Registration API | Graph beta; production use explicitly unsupported | Direct Registry provisioning cannot be called production-ready | Workflow-v3 delegated administrator completion gate, exact OBO scopes, no app-only or CLI fallback |
| Agent ID product/portal rollout | Dedicated method pages are v1.0 while some older how-to/CLI text still says beta or the portal displays Preview | Tenant permission visibility can lag the method contract | Preflight the exact application roles and retain integration tests against the selected tenant; cite the dedicated v1.0 method pages |
| Agent user / AI-teammate instance | Frontier preview and Microsoft 365 licensing | Optional Teams/M365 user experience isn't universally available | Keep outside standard provisioning; expose only after tenant and license preflight |
| AgentX V2 registration transport | Used by the official CLI but no public server-side contract was validated | Gateway can't reproduce or invent the CLI transport | Use a documented SDK/CLI provider or remain blocked for production registration |

---

## 6. Unsupported Capabilities

| Capability | Status | Impact | Gateway Decision |
|---|---|---|---|
| Production use of the public direct Agent Registry API | Microsoft explicitly doesn't support production applications on Graph beta | Standard Entra Agent ID creation can complete, but production registry publication lacks an approved direct Gateway contract | Fail closed unless a separately validated supported provider is configured |
| Optional Teams/AI-teammate instance creation through a Gateway REST call | No public server-side create contract was validated; documented path is publish → Teams request → tenant-admin approval | Optional instance/user lifecycle can't be represented as an automatic standard provisioning step | Model a separate `AwaitingInstanceApproval` workflow only after a real request exists |
| Gateway as `managerApplication` | First-party apps only | Gateway can't add itself or invent a manager ID | Create a blueprint principal with least privilege and use its automatic `AgentIdentity.CreateAsManager`; require provider/bootstrap preflight for Agent 365 platform acceptance |
| Convert an ordinary Entra app or the Gateway API app into an Agent ID blueprint | Microsoft documents no in-place conversion | Reusing an existing app ID would bypass the typed blueprint model and fail identity/lifecycle assumptions | Create or select a typed reusable blueprint; migrate runtime code to the new Agent Identity and retire the old app separately |
| Worker-managed-identity authentication to Agent 365 CLI | Current CLI docs require a delegated public-client app and signed-in user | The proposed background token-cache injection isn't a documented mechanism | Do not implement the CLI sidecar auth design; use explicit administrator-run CLI or another supported provider |
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
| 4 | OTLP endpoint accepts S2S auth from the Gateway using each registration's mapped child Agent ID | Medium | Validate that telemetry is correctly attributed per-agent |
| 5 | External agents can reliably provide `tenantUserObjectId` for Purview evaluation | Medium | Design requires this — document as integration contract |
| 6 | A registration-bound Gateway API key prevents cross-registration ingress | Medium until deployed | Run readiness and controlled data-plane canaries with matching and mismatched `externalAgentId`; never print the key |
| 7 | Workload identity federation credential limits are sufficient for one Gateway FIC per selected reusable blueprint | Low | Preflight the documented platform limits before onboarding additional Gateway identities |
| 8 | Agent 365 resource app exposes `Agent365.Observability.OtelWrite` for assignment to child Agent Identities | Low | Preflight the resource service principal/role, then verify each workflow-created assignment and token claim |

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

**Status:** Superseded by the workflow-v3 delegated administrator decision on 2026-08-27.

**Context:** The public direct Agent Registration API (`/beta/copilot/agentRegistrations`) remains beta and isn't supported for production. Current CLI documentation describes a different AgentX V2 registration step, but doesn't publish that transport as a server-side Gateway contract.

**Decision:** Workflow v3 pauses the worker at 71% and completes Registry through a
signed-in Gateway administrator API action. The API enforces user authentication,
`Gateway.Administrator`, valid `oid`, and delegated `access_as_user`, then performs
OBO for the two admin-consented Registry scopes using its managed-identity signed
assertion. It persists creator-bound intent with a planned `id`, emits at most one
POST with that ID and the reviewed `managedByAppId`, and immediately persists the
safe returned/fallback ID on HTTP 201. Unknown outcomes use exact planned-ID GET
only. Never fall back to app-only, CLI process execution, or a second POST.

**Consequences:** Continuous development has completed this delegated boundary and
final verification for both blueprint modes. Production
Registry support remains unclaimed. The historical v2 app-only request stays
unresolved and is never retried or attached.

### ADR-002: managerApplications Constraint

**Status:** Superseded in part by the 2026-08-24 revalidation.

**Context:** The `managerApplications` property accepts only Microsoft first-party application IDs, so the Gateway can't designate itself. Separately, Microsoft Entra automatically grants `AgentIdentity.CreateAsManager` to every created agent identity blueprint principal.

**Decision:** Create the blueprint principal with the least-privileged `AgentIdentityBlueprintPrincipal.Create` permission and use the principal's automatic manager permission where appropriate. Don't grant `AgentIdentityBlueprintPrincipal.ReadWrite.All` merely as a workaround for `managerApplications`. For the current development tenant/provider, use the independently verified Microsoft 365 App Catalog Services input correlated from A365 CLI `1.1.214+90c444832f` and tenant inventory. Revalidate it after tenant/provider/CLI changes and never publish it as a universal Gateway constant.

**Consequences:** Entra Agent Identity creation is programmatic, but Agent 365 platform acceptance remains a separate provider prerequisite.

### ADR-003: Purview User Context Requirement

**Context:** User-scoped Purview `processContent` calls require a valid Entra user ID. The `/users/{id}` route supports application permissions; `/me` does not. There is no anonymous evaluation mode.

**Decision:** External agents MUST provide a valid `tenantUserObjectId` in every Purview-enabled interaction. The Gateway uses its managed-identity application token and fails validation before content persistence when user context is missing or malformed. It does not require or perform a separate `User.Read.All` lookup; Microsoft Graph validates the user on the data-security request.

**Consequences:** External agents that cannot provide user context cannot enable Purview for that registration. The Gateway never substitutes the signed-in administrator or fabricates an identity.

### ADR-004: Instance Provisioning Manual Step

**Status:** Superseded by the 2026-08-24 standard-Agent-ID revalidation; retained only for the optional Teams/AI-teammate workflow.

**Context:** The standard blueprint → blueprint principal → Agent Identity workflow is available through Microsoft Graph v1.0 and doesn't require per-agent approval. The documented Teams/AI-teammate flow is separate: publish the agent, configure its messaging endpoint, request an instance in Teams, and obtain tenant-admin approval.

**Decision:** A standard verified Agent ID and registry registration becomes
`Active`/`Registered` only after the workflow-v3 delegated administrator completion
and final worker verification. The implemented `AwaitingAdminApproval` status is the
71% user-action boundary; it is not a Teams instance approval claim. A future optional Teams instance
flow must use a distinct status such as `AwaitingInstanceApproval`, and only after a
real instance request exists.

**Consequences:** Standard provisioning isn't blocked on Teams approval. The optional instance/user workflow remains administrator-mediated and must not be implied by the current registration form.

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

## Current validation follow-ups

1. **Production registry provider:** Select a documented supported path compatible with the Gateway's requirement that external agents don't embed the Agent 365 SDK or CLI.
2. **N:N workflow-v3 proof -- complete in development:** The delegated Registry
   scopes, tenant-wide consent, API managed-identity FIC, eight-role worker boundary,
   isolated queue, both blueprint modes, final `Active` verification, registration-
   bound ingress, child token, Admin Center visibility, and prompt DLP are verified.
   The next validation target is staging multi-replica/failover behavior. Preserve
   and never retry/attach the historical v2 app-only HTTP 500 request.
3. **Observability attribution and landing:** Validate that S2S telemetry is
   attributed to the correct child Agent ID and blueprint. Treat OTLP HTTP 200 as
   endpoint acceptance only; verify delayed `CloudAppEvents` landing independently
   before recording the telemetry canary complete.
4. **Purview user context flow -- resolved in the current contract:** interactions
   carry the Entra tenant user object ID used for Purview evaluation; missing/invalid
   context follows the documented fail/skip policy.
5. **Provisioning state naming -- resolved:** implemented
   `AwaitingAdminApproval` is for a real permission/admin handoff. The optional
   Teams-instance lifecycle is not implemented and must use a distinct future
   `AwaitingInstanceApproval` status after a real request exists. Standard Agent ID
   creation has neither state after a successful tenant preflight.

## Microsoft Documentation Citations

All URLs in this document are from official Microsoft Learn documentation. The
Agent ID, Agent 365 Registry, blueprint, and Purview sources relevant to the current
contract were rechecked through 2026-08-28; other links retain their earlier
validation dates:

- Agent 365 Developer: https://learn.microsoft.com/microsoft-agent-365/developer/
- Agent 365 Identity: https://learn.microsoft.com/microsoft-agent-365/developer/identity
- Agent 365 Registration Setup: https://learn.microsoft.com/microsoft-agent-365/developer/registration
- Create Agent Identity Blueprint: https://learn.microsoft.com/graph/api/agentidentityblueprint-post?view=graph-rest-1.0
- Configure Agent Identity Blueprint: https://learn.microsoft.com/entra/agent-id/create-blueprint
- Reusable Agent Identity Blueprint Model: https://learn.microsoft.com/entra/agent-id/agent-blueprint
- Migrate Ordinary App Registrations to Agent ID: https://learn.microsoft.com/entra/agent-id/migrate-custom-app-registrations-to-agent-id
- Autonomous Agent Identity Token Flow: https://learn.microsoft.com/entra/agent-id/autonomous-agent-authentication-authorization-flow
- Create Federated Identity Credential: https://learn.microsoft.com/graph/api/federatedidentitycredential-post?view=graph-rest-1.0
- Get Federated Identity Credential by ID or Name: https://learn.microsoft.com/graph/api/federatedidentitycredential-get?view=graph-rest-1.0
- Federated Identity Credential Propagation Considerations: https://learn.microsoft.com/entra/workload-id/workload-identity-federation-considerations
- List Blueprint Federated Identity Credentials (beta typed read): https://learn.microsoft.com/graph/api/federatedidentitycredential-list?view=graph-rest-beta
- Grant a Gateway App Role to an Agent Identity: https://learn.microsoft.com/graph/api/serviceprincipal-post-approleassignments?view=graph-rest-1.0
- Create Blueprint Principal: https://learn.microsoft.com/graph/api/agentidentityblueprintprincipal-post?view=graph-rest-1.0
- Get Blueprint Principal: https://learn.microsoft.com/graph/api/agentidentityblueprintprincipal-get?view=graph-rest-1.0
- Create Agent Identity: https://learn.microsoft.com/graph/api/agentidentity-post?view=graph-rest-1.0
- Agent Identity Creation Channels: https://learn.microsoft.com/entra/agent-id/agent-id-creation-channels
- Create Agent Registration: https://learn.microsoft.com/microsoft-365/copilot/extensibility/api/admin-settings/agent-registration/agentregistration-create
- Agent Registration API Overview: https://learn.microsoft.com/microsoft-365/copilot/extensibility/api/admin-settings/agent-registration/overview
- Agent 365 CLI Setup: https://learn.microsoft.com/microsoft-agent-365/developer/reference/cli/setup
- Agent 365 CLI Client Authentication: https://learn.microsoft.com/microsoft-agent-365/developer/custom-client-app-registration
- Optional Agent Instance: https://learn.microsoft.com/microsoft-agent-365/developer/create-instance
- Purview Developer: https://learn.microsoft.com/purview/developer/secure-ai-with-purview
- Purview API Tutorial: https://learn.microsoft.com/purview/developer/use-the-api
- Graph Permissions: https://learn.microsoft.com/graph/permissions-reference
- Entra Identity Platform: https://learn.microsoft.com/entra/identity-platform/
- Microsoft Identity Web: https://learn.microsoft.com/entra/msidweb/getting-started/quickstart-webapi
- Azure Storage Private Endpoints: https://learn.microsoft.com/azure/storage/common/storage-private-endpoints
- Azure Private Endpoint DNS Zones: https://learn.microsoft.com/azure/private-link/private-endpoint-dns
- Subscription-scope Bicep deployments and resource-group modules: https://learn.microsoft.com/azure/azure-resource-manager/bicep/deploy-to-subscription
- Agent 365 CLI installation: https://learn.microsoft.com/microsoft-agent-365/developer/agent-365-cli
- Microsoft identity consent model: https://learn.microsoft.com/entra/identity-platform/permissions-consent-overview
- Purview custom-AI-app collection/DLP configuration (`Application` enforcement plane): https://learn.microsoft.com/purview/developer/configurepurview
