# Microsoft Entra ID Setup Runbook

This runbook covers the Microsoft Entra ID configuration required for the A365
Custom Gateway. It includes app registrations for the Gateway API and Admin UI,
  reusable Agent ID blueprints and child Agent IDs for outbound Agent 365 routing,
application permissions, workload identity federation, and role assignments. It is
not deployment proof; follow the explicit workflow-v3 activation gates below.

All commands use the Azure CLI (`az`) and Microsoft Graph CLI (`az ad`). PowerShell alternatives are noted where applicable.

---

## Prerequisites

| Requirement | Details |
|---|---|
| **Entra role** | Application Administrator (or Global Administrator) for the app-registration setup steps; Privileged Role Administrator for the Step 4 Microsoft Graph application-role grants. Some separately authorized Agent 365 delegated/OAuth grant workflows require Global Administrator. |
| **Azure CLI** | v2.60+ with `account` and `ad` extensions |
| **Microsoft Graph permissions** | `Application.ReadWrite.All`, `AppRoleAssignment.ReadWrite.All`, `Directory.Read.All` (for the operator running this runbook) |
| **Tenant ID** | `{tenantId}` |
| **Subscription** | `{subscriptionId}` |
| **Gateway API domain** | `{gatewayDomain}` (e.g., `gateway-api.{region}.azurecontainerapps.io`) |
| **Admin UI domain** | `{adminUiDomain}` (e.g., `gateway-admin.{region}.azurecontainerapps.io`) |
| **GitHub repository** | `{githubOrg}/{githubRepo}` (for workload identity federation) |

Current development boundary (2026-08-28): workflow-v3 continuous mode is live for
both create-new and reuse-existing blueprint paths. Both registrations are Active
and Available in Microsoft 365 Admin Center. API revision
`ca-gateway-api-dev--purviewguard-20260828222324` and worker revision
`ca-gateway-worker-dev-vnet--rbacrefresh-202608282058` are healthy. The v3 queue is
`0/0/9`; retained v2 is `0/0/3`, and historical v1 is `0/0/2`. The typed catalog
last proved 7 compatible/selectable and 5 incompatible/disabled rows.

The three bounded v2 failures remain historical and immutable. In particular, the
third created a child Agent ID and OtelWrite assignment but its app-only Registry
POST returned HTTP 500 without a durable ID. Only read-only Registry/Admin Center
reconciliation is permitted for that exact request, but it is not a workflow-v3
input and must never be retried, attached, or cleaned up. Workflow v3 instead gives
the worker eight non-Registry Graph app roles and moves Registry completion to a
signed-in administrator API action using exact delegated OBO scopes. Four historical
exact-bound browser windows closed without submission before the first successful v3
canary. Current continuous paths accepted durable Registry IDs, completed final
verification, returned HTTP 202 for matched Gateway ingress, and received Agent 365
OTLP HTTP 200. Blueprint-scoped Purview Enforce proved benign audit and synthetic
prompt blocking while honoring inline upload/offline download modes. The older
`live-state-20260828-v3-success-final.json` artifact predates the continuous canaries
and is not current SQL evidence. SQL finalization remains unapplied.
The development provider input was independently correlated from A365 CLI
`1.1.214+90c444832f` and read-only tenant inventory to verified Microsoft 365 App
Catalog Services; it remains tenant/provider configuration, not a universal
constant. Read exact gates, DLQ evidence, and finalize status from
[`development-deployment-status.md`](development-deployment-status.md).

### Login

```bash
az login --tenant {tenantId}
az account set --subscription {subscriptionId}
```

---

## Step 1: Create the Gateway API App Registration

The Gateway API app registration exposes the delegated `access_as_user` scope for the
Admin UI and retains five application roles for control-plane and legacy contract
compatibility. Current N:N external agents use a unique per-registration Gateway API
key, not the delegated scope or the legacy child `ExternalAgent` role.

### 1.1 Create the App Registration

```bash
az ad app create \
  --display-name "A365 Gateway API" \
  --sign-in-audience "AzureADMyOrg" \
  --identifier-uris "api://{gatewayApiClientId}" \
  --query "appId" -o tsv
```

> Save the returned `appId` as `{gatewayApiClientId}`.

After creation, update the identifier URI to use the appId:

```bash
az ad app update \
  --id {gatewayApiClientId} \
  --identifier-uris "api://{gatewayApiClientId}"
```

### 1.2 Expose API Scopes

Define the delegated scope requested by the Admin UI. External Agent Identities use
the application role defined in the next section, not this scope:

```bash
# Generate a scope ID
SCOPE_ID=$(uuidgen)

az ad app update \
  --id {gatewayApiClientId} \
  --set api='{
    "oauth2PermissionScopes": [
      {
        "id": "'"$SCOPE_ID"'",
        "adminConsentDescription": "Access the A365 Gateway API",
        "adminConsentDisplayName": "Access A365 Gateway API",
        "isEnabled": true,
        "type": "Admin",
        "value": "access_as_user"
      }
    ]
  }'
```

### 1.3 Define Application Roles

Define the five application roles that match the gateway's authorization model:

```bash
az ad app update \
  --id {gatewayApiClientId} \
  --app-roles '[
    {
      "allowedMemberTypes": ["User"],
      "description": "Full control-plane access. Configure gateway, register and delete agents, start provisioning, enable or disable integrations, assign operators and auditors.",
      "displayName": "Gateway Administrator",
      "isEnabled": true,
      "value": "Gateway.Administrator",
      "id": "'$(uuidgen)'"
    },
    {
      "allowedMemberTypes": ["User"],
      "description": "View agents, enable or disable agents, and view non-sensitive operational and provisioning status.",
      "displayName": "Gateway Operator",
      "isEnabled": true,
      "value": "Gateway.Operator",
      "id": "'$(uuidgen)'"
    },
    {
      "allowedMemberTypes": ["User"],
      "description": "Read configuration history, status, and audit events. Cannot modify agents or reveal secrets.",
      "displayName": "Gateway Auditor",
      "isEnabled": true,
      "value": "Gateway.Auditor",
      "id": "'$(uuidgen)'"
    },
    {
      "allowedMemberTypes": ["User"],
      "description": "Read health and diagnostics with sensitive information redacted.",
      "displayName": "Gateway Support Reader",
      "isEnabled": true,
      "value": "Gateway.SupportReader",
      "id": "'$(uuidgen)'"
    },
    {
      "allowedMemberTypes": ["Application"],
      "description": "Data-plane access only. Submit activities, prompts, and responses for the bound agent registration. Cannot access management endpoints.",
      "displayName": "External Agent",
      "isEnabled": true,
      "value": "ExternalAgent",
      "id": "'$(uuidgen)'"
    }
  ]'
```

> **Important:** The first four roles use `"allowedMemberTypes": ["User"]` for
> interactive admin/operator/auditor/support access. `ExternalAgent` remains
> application-only for legacy contract compatibility, but current N:N workflow v3
> does not assign it to child Agent IDs. New external agents use their unique Gateway
> API key for data-plane ingress.

### 1.4 Create a Service Principal for the Gateway API

```bash
az ad sp create --id {gatewayApiClientId}
```

### Verification -- Step 1

```bash
# Confirm the app registration exists
az ad app show --id {gatewayApiClientId} --query "{appId:appId, displayName:displayName, identifierUris:identifierUris}" -o table

# Confirm scopes are exposed
az ad app show --id {gatewayApiClientId} --query "api.oauth2PermissionScopes[].{value:value, isEnabled:isEnabled}" -o table

# Confirm all 5 app roles
az ad app show --id {gatewayApiClientId} --query "appRoles[].{displayName:displayName, value:value, memberTypes:allowedMemberTypes}" -o table

# Confirm service principal
az ad sp show --id {gatewayApiClientId} --query "appId" -o tsv
```

---

## Step 2: Create the Gateway Web (Admin UI) App Registration

The Admin UI is a Blazor Web App that authenticates administrators, operators, and auditors via the OIDC authorization code flow. It requests delegated access to the Gateway API.

### 2.1 Create the App Registration

```bash
az ad app create \
  --display-name "A365 Gateway Admin UI" \
  --sign-in-audience "AzureADMyOrg" \
  --web-redirect-uris \
    "https://{adminUiDomain}/signin-oidc" \
    "https://localhost:7198/signin-oidc" \
  --enable-id-token-issuance true \
  --query "appId" -o tsv
```

> Save the returned `appId` as `{adminUiClientId}`.

### 2.2 Add a Client Secret (Development Only)

Prefer a certificate or managed identity. If a development client secret is an
explicitly approved exception, create it only through a vault-integrated privileged
workflow that writes the one-time returned value directly to Key Vault. Do not run a
credential-reset command that prints the password to a terminal, CI log, transcript,
or agent tool output, and do not pass the value as a command-line argument. Record
only the Key Vault reference and credential key ID.

### 2.3 Grant Delegated Permission to the Gateway API

```bash
# Get the scope ID from Step 1
SCOPE_ID=$(az ad app show --id {gatewayApiClientId} --query "api.oauth2PermissionScopes[0].id" -o tsv)

# Add the permission
az ad app permission add \
  --id {adminUiClientId} \
  --api {gatewayApiClientId} \
  --api-permissions "${SCOPE_ID}=Scope"
```

### 2.4 Configure Logout URIs

```bash
az ad app update \
  --id {adminUiClientId} \
  --web-home-page-url "https://{adminUiDomain}" \
  --set "web.logoutUrl='https://{adminUiDomain}/signout-oidc'"
```

### Verification -- Step 2

```bash
# Confirm the app registration
az ad app show --id {adminUiClientId} --query "{appId:appId, displayName:displayName}" -o table

# Confirm redirect URIs
az ad app show --id {adminUiClientId} --query "web.redirectUris" -o json

# Confirm API permission
az ad app permission list --id {adminUiClientId} -o table
```

---

## Step 3: Prepare the Reusable Blueprint and Gateway Worker Identity

Workflow v3 does **not** create an ordinary external-agent app registration. A normal
Entra app, service principal, or the Gateway API app cannot be selected or converted
in place as an Agent ID blueprint. Microsoft documents migration as creating new
Agent ID resources alongside the old identity. See the
[blueprint model](https://learn.microsoft.com/entra/agent-id/agent-blueprint) and
[migration boundary](https://learn.microsoft.com/entra/agent-id/migrate-custom-app-registrations-to-agent-id).

Do not submit a registration merely while following this setup section. The reviewed
additive database prepare, Graph consent, workflow-v3 deployment, and prior
execution-ready preflights completed, while all three retained v2 canaries remain
immutable manual-intervention evidence. The Registry-unknown third v2 canary still
requires Microsoft reconciliation and permits no second POST, retry, attachment, or
cleanup; it is not an input or prerequisite for the fresh v3 canary now paused at
71%. Do not create another registration. Completion requires fresh post-registration
SQL/outbox evidence and the narrow worker-only completion rearm while the deployed
API remains closed, and only after the refreshed Azure CLI session proves the exact
retained-FIC GET. Never run controller `Arm` in this post-registration state. The current
prerequisite script's `-RequireExecutionReady` mode correctly requires neither a
Gateway `ExternalAgent` app-role client ID nor a generated-app-password vault; an
explicitly supplied legacy vault is optional/read-only. It remains only one part of
the supplemented gate. Follow the exact checks and activation order in
[`agent-guides/provisioning.md`](../agent-guides/provisioning.md).

### 3.1 Choose the Reusable Blueprint Mode

- `UseExisting`: the Admin UI lists existing typed Agent ID blueprints through
  `GET /api/v1/agent-identity-blueprints`; select one item from that dropdown. The
  catalog/API carries its object ID internally. Do not ask the operator to paste an
  object/client ID or select an ordinary app.
- `CreateNew`: provide a stable display name for a reusable blueprint. The worker
  resolves its deterministic key before creating the typed resource and persists
  both object ID and client/app ID.

One blueprint may create multiple distinct Agent Identities for agents of the same
type. Each registration still receives its own child Agent Identity.

Keep identifier semantics explicit: a blueprint's Graph object `id` and application
`appId` are separate named fields whose values may coincide. Read-only development
inventory has observed equal pairs; the last independently captured catalog
contained 12 typed blueprints, and a later create-new flow means that count must be
recaptured before reuse. Retain both returned
fields and use the one required by each route; do not reject equality or infer a
field from it. Microsoft currently documents the child Agent Identity object ID and
application/client ID as the same GUID; retain both field names where the Gateway
contract uses them, verify that child equality, and never substitute a blueprint-
principal or Gateway-owned registration ID.

### 3.2 Configure the Gateway Worker Principal

Set `Agent365__ProvisioningManagedIdentityPrincipalId` to the Entra
**service-principal object ID** (`principalId`) of the exact worker managed identity.
Do not substitute its client ID, Azure resource ID, signed-in user ID, blueprint ID,
or child Agent ID. Workflow v3 verifies the caller token `oid`, then creates or
verifies one deterministic FIC for that Gateway worker on each selected reusable
blueprint. The FIC must contain the exact deterministic name, tenant issuer, worker
subject, and a collection with exactly one `api://AzureADTokenExchange` audience.
Reusing a blueprint must not create one FIC per registration.

Microsoft Graph documents that [FIC create](https://learn.microsoft.com/graph/api/federatedidentitycredential-post?view=graph-rest-1.0)
returns HTTP 201 plus the created object and that it can later be
[read by ID or name](https://learn.microsoft.com/graph/api/federatedidentitycredential-get?view=graph-rest-1.0).
Microsoft also documents that [federation changes take time to
propagate](https://learn.microsoft.com/entra/workload-id/workload-identity-federation-considerations).
The Gateway emits at most one POST for a logical FIC, preserves the returned ID, and
uses bounded, cancellation-aware GET-only reconciliation. Missing, duplicate,
mismatched, or null results fail closed without a second POST. This schedule is a
Gateway recovery policy derived from the documented create/get and propagation
behavior, not an official immediate-consistency promise.

Development already contains exactly one reconciled FIC on the selected
`simple-echo-agent Blueprint`. Preserve it. Every authorized registration must
discover and reuse it through GET and issue no FIC POST. Neither retained failed registration is a
retry input.

The registration form does not accept an external-runtime managed-identity object
ID. External clients authenticate to the Gateway with their one-time-issued
per-registration API key and need no Entra credential for normal ingress.

### 3.3 Workflow-Assigned Resource Access

After creating the child Agent ID, `AssignAgent365Access` assigns only Agent 365
`Agent365.Observability.OtelWrite` on resource application
   `9b975845-388f-4429-889e-eab1ef63949c`.

The role IDs are resolved dynamically. The worker/exporter identity is not the
per-agent telemetry identity.

### Verification -- Step 3

The workflow final stage must re-read the blueprint, principal, one Gateway FIC with
exactly one audience, child Agent ID, and Agent 365 role assignment. It trusts only
the API-persisted, delegated Registry evidence and performs no Registry HTTP. It then uses
the worker FIC with `fmi_path=<child-agent-id>` and validates the child Agent ID's
Agent 365 observability token. There is no child Gateway token or readiness self-call.
Never print assertions, tokens, or full decoded claims.

---

## Step 4: Grant Admin Consent for Microsoft Graph Permissions

The provisioning worker identity needs Microsoft Graph **application roles** for the
workflow-v3 worker stages. The only permitted target is the exact managed-identity
principal resolved from the reviewed v3 worker deployment; reject the historical
`ca-gateway-worker-dev` principal and any retained v1/v2 receiver explicitly. These
are directory app-role
assignments on the Microsoft Graph service principal; they are not Azure resource
RBAC role assignments. Do not grant the worker allowlist to the historical worker,
Gateway API, or Admin UI merely because those components are easier to locate. The
Gateway API separately needs the catalog application role plus the delegated OBO
configuration documented below.

Revalidate the exact roles immediately before use against
[`docs/architecture/doc-validation-matrix.md`](../architecture/doc-validation-matrix.md)
and the linked official Microsoft pages. Keep all provisioning/Registry gates inert
until this preflight succeeds.

### 4.0 Gateway API identity -- typed blueprint catalog

The deployed API managed identity backs
`GET /api/v1/agent-identity-blueprints` and requires the Microsoft Graph
application role `AgentIdentityBlueprint.Read.All`, with tenant admin consent. This
is separate from the worker allowlist and from the signed-in administrator's
delegated Gateway token. Resolve the role by value on the Microsoft Graph service
principal, assign it only to the API managed-identity service principal, and verify
the resulting app-role assignment before deploying the catalog route. Do not grant
the API write/create/add-remove-credentials roles.

### 4.1 Provisioning worker -- Graph application roles

Workflow v3 uses this exact eight-role application allowlist on the v3 worker managed
identity. The two Agent Registration roles used by the retained workflow-v2 contract
are not v3 worker permissions:

1. `Application.Read.All`
2. `AppRoleAssignment.ReadWrite.All`
3. `AgentIdentityBlueprint.Create`
4. `AgentIdentityBlueprint.AddRemoveCreds.All`
5. `AgentIdentityBlueprintPrincipal.Create`
6. `AgentIdentityBlueprint.Read.All`
7. `AgentIdentity.Create.All`
8. `AgentIdentity.Read.All`

`AgentIdentityBlueprint.AddRemoveCreds.All` is required because v3 creates/verifies
the one Gateway-worker blueprint FIC. `Application.ReadWrite.OwnedBy` belonged to
workflow v1's ordinary-app creation and is not a v3 permission. Do not add
`AgentIdentityBlueprintPrincipal.Read.All`: current principal verification uses
`GET /v1.0/servicePrincipals/{id}/microsoft.graph.agentIdentityBlueprintPrincipal`,
and Microsoft documents `Application.Read.All` as an accepted application permission
for that typed GET. The current allowlist already requires `Application.Read.All` for
downstream resource and app-role resolution. Resolve every role by tenant-published
`value`, not a copied GUID. The reviewed v3 deployment/preflight must prove exactly
these eight effective Graph application roles and no Registry roles before execution.

### 4.2 Gateway API -- delegated Registry OBO boundary

Registry completion belongs to the Gateway API and the signed-in administrator, not
the worker. Configure all of these together while the API and worker gates remain
inert:

- Gateway API `requiredResourceAccess` contains the delegated Microsoft Graph scopes
  `AgentRegistration.ReadWrite.All` and `AgentRegistration.Read.All`.
- The Gateway API service principal has tenant-wide (`AllPrincipals`) admin consent
  for both scopes. Preserve any existing consented scopes; do not replace the grant.
- The Gateway API application has one exact federated identity credential whose
  issuer is the pinned tenant v2 issuer, subject is the Gateway API Container App
  managed-identity **principal/object ID**, and sole audience is
  `api://AzureADTokenExchange`.
- The workflow-v3 worker has neither Registry application role, leaving only the
  eight-role allowlist above.

The API accepts Registry completion only from an authenticated user token with
`Gateway.Administrator`, a valid `oid`, and delegated `access_as_user`. It exchanges
that assertion through OBO using the managed-identity signed assertion. App-only
tokens are rejected. Admin consent is a deployment prerequisite; it is not a
per-registration prompt.

Use the reviewed helper. It is read-only unless `-Apply` is supplied, pins the Azure
subscription and tenant, resolves permission IDs from the tenant, preserves existing
requested/consented scopes, creates only the exact named FIC, and removes only the
two obsolete worker Registry assignments. It never acquires or prints a token or
credential.

First run the read-only plan from PowerShell 7:

```powershell
pwsh ./tools/configure-workflow-v3-entra.ps1 `
  -ExpectedSubscriptionId '{development-subscription-id}' `
  -ExpectedTenantId '{development-tenant-id}' `
  -GatewayApiApplicationClientId '{gateway-api-application-client-id}' `
  -GatewayApiManagedIdentityPrincipalId '{gateway-api-managed-identity-principal-id}' `
  -WorkerManagedIdentityPrincipalId '{workflow-v3-worker-managed-identity-principal-id}'
```

Review every `[PLAN]` category and verify the resolved IDs against the pinned
development inventory. Then, with the same parameters, add `-Apply` once. Do not use
blanket `az ad app permission admin-consent`, change the default FIC name without a
reviewed collision check, or target a v1/v2 worker. Re-run the command without
`-Apply` and run the independent read-only provisioning preflight; both must pass
before enabling any v3 gate.

### 4.3 Agent 365 `managerApplications` provider prerequisite

Agent 365 accepts only Microsoft first-party application IDs in a blueprint's
`managerApplications` collection, with at most ten entries. This is a platform
acceptance prerequisite distinct from the worker's Graph roles and from the blueprint
principal's automatic `AgentIdentity.CreateAsManager` permission.

- Obtain one to ten IDs only from an official provider/bootstrap result or an
  independently verified Microsoft source. For the current development tenant, the
  reviewed input was correlated on 2026-08-25 from installed A365 CLI
  `1.1.214+90c444832f` and read-only blueprint/service-principal inventory to
  verified-publisher Microsoft 365 App Catalog Services. Revalidate after CLI/
  provider changes and never treat that tenant result as universal.
- Never put the Gateway API, worker managed identity, Admin UI, or an arbitrary tenant
  application ID in this collection.
- Supply the reviewed set through `AGENT365_MANAGER_APPLICATION_IDS_JSON` (or the
  equivalent `agent365ManagerApplicationIds` Bicep parameter) without printing the
  values in logs. The reviewed Bicep path projects the same indexed
  `Agent365__ManagerApplicationIds__N` values into both API and worker so the catalog,
  registration boundary, and final worker check use one configuration.
- Set `agent365ManagerApplicationsPreflightConfirmed=true` only after that independent
  verification. For a Gateway-created blueprint, the adapter requires exact,
  order-insensitive equality. For a selected typed blueprint, it requires every
  configured ID but preserves additional provider-issued first-party managers that
  may already be present. A missing required ID fails closed.
- The delegated Agent 365 CLI may perform provider bootstrap in a signed-in
  administrator workflow, but it is not an unattended managed-identity fallback for
  the worker.

Do not enable workflow-v3 provisioning execution until this prerequisite is
satisfied. Record the verification source and date in the deployment handoff without
copying tokens or secrets.

Workflow-v3 Registry create persists and sends a creator-bound planned `id` plus the
reviewed direct-preview provider `managedByAppId`. It uses the Gateway external ID
as `sourceAgentId`, stored owner IDs, the signed-in user's `oid` as `createdBy`, and
the persisted child/blueprint identifiers. HTTP 201 persists the safe returned ID,
using the planned ID only when the successful response omits one. Unknown outcomes
permit exact planned-ID GET only and never a second POST.

### 4.4 Child Agent ID Resource Role

The Graph permission above authorizes the worker to create the one exact app-role
assignment during `AssignAgent365Access`. It does not make the worker the application
principal for the downstream resource:

- Agent 365 `Agent365.Observability.OtelWrite` -> child Agent ID on resource
  application `9b975845-388f-4429-889e-eab1ef63949c`.

Preflight that the resource service principal and application-role value exist.
Resolve the role ID dynamically and verify the assignment's `principalId`,
`resourceId`, and `appRoleId`. Do not assign the legacy Gateway `ExternalAgent` role
to the child, and do not grant `Agent365.Observability.OtelWrite` to the worker as a
substitute for the per-agent assignment.

### 4.5 Administrative boundary

Microsoft's current Agent ID guidance identifies Privileged Role Administrator as the
least-privileged role for granting Microsoft Graph application permissions. Some
Agent 365 delegated/OAuth grant workflows require Global Administrator. These are
one-time permission/consent boundaries. Workflow v3 then requires a signed-in Gateway
administrator for each Registry completion action because Microsoft Graph evaluates
the delegated administrator identity at that boundary.

Do not use `az ad app permission admin-consent` against a system-assigned managed
identity. Verify the app-role assignments directly on the worker service principal.

### 4.6 Verify Consent Status

```powershell
az rest --method GET `
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/{newVnetWorkerManagedIdentityObjectId}/appRoleAssignments" `
    --query "value[].{resourceId:resourceId,appRoleId:appRoleId}" `
    --output table
```

### Verification -- Step 4

1. Confirm the principal ID belongs to the new `ca-gateway-worker-dev-vnet`
   system-assigned identity. Reject the historical `ca-gateway-worker-dev` principal,
   API, Admin UI, deployment identity, and every external-agent identity.
2. Resolve every returned `appRoleId` back to the current Microsoft Graph `appRoles`
   collection and compare the values with the reviewed allowlist.
3. Confirm the provisioning-specific feature gate remains disabled until worker SQL,
   Graph token acquisition, Registry preview configuration, and recovery preflight all
   pass.
4. Record only role values and safe object references in the deployment checkpoint;
   never record tokens, credentials, or `.secrets` values.

---

## Step 5: Configure Workload Identity Federation for GitHub Actions

Workload identity federation enables the GitHub Actions CI/CD pipeline to authenticate to Azure without storing client secrets. This uses OIDC token exchange.

### 5.1 Create a Deployment App Registration

```bash
az ad app create \
  --display-name "A365 Gateway - GitHub Actions Deployment" \
  --query "appId" -o tsv
```

> Save as `{deploymentClientId}`.

### 5.2 Create a Service Principal

```bash
az ad sp create --id {deploymentClientId}
```

### 5.3 Add Federated Credentials

Create federated credentials for each GitHub environment or branch that will deploy:

```bash
# Production environment
az ad app federated-credential create \
  --id {deploymentClientId} \
  --parameters '{
    "name": "github-actions-prod",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:{githubOrg}/{githubRepo}:environment:production",
    "audiences": ["api://AzureADTokenExchange"],
    "description": "GitHub Actions deployment to production"
  }'

# Staging environment
az ad app federated-credential create \
  --id {deploymentClientId} \
  --parameters '{
    "name": "github-actions-staging",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:{githubOrg}/{githubRepo}:environment:staging",
    "audiences": ["api://AzureADTokenExchange"],
    "description": "GitHub Actions deployment to staging"
  }'

# Main branch (for CI builds)
az ad app federated-credential create \
  --id {deploymentClientId} \
  --parameters '{
    "name": "github-actions-main",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:{githubOrg}/{githubRepo}:ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"],
    "description": "GitHub Actions CI on main branch"
  }'
```

> **Note:** Workload identity federation supports a maximum of 20 federated credentials per app registration. Plan credential subjects carefully.

### 5.4 Assign Azure Roles to the Deployment Service Principal

```bash
DEPLOYMENT_SP_OBJECT_ID=$(az ad sp show --id {deploymentClientId} --query "id" -o tsv)

# Contributor on the resource group (for Bicep deployments)
az role assignment create \
  --assignee-object-id ${DEPLOYMENT_SP_OBJECT_ID} \
  --assignee-principal-type ServicePrincipal \
  --role "Contributor" \
  --scope "/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}"

# AcrPush on the container registry (for image pushes)
az role assignment create \
  --assignee-object-id ${DEPLOYMENT_SP_OBJECT_ID} \
  --assignee-principal-type ServicePrincipal \
  --role "AcrPush" \
  --scope "/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.ContainerRegistry/registries/{acrName}"
```

### 5.5 Configure GitHub Repository Secrets

In the GitHub repository, add these secrets under **Settings** > **Secrets and variables** > **Actions**:

| Secret Name | Value |
|---|---|
| `AZURE_CLIENT_ID` | `{deploymentClientId}` |
| `AZURE_TENANT_ID` | `{tenantId}` |
| `AZURE_SUBSCRIPTION_ID` | `{subscriptionId}` |

> No client secret is needed. The workflow uses `azure/login@v2` with OIDC.

### Verification -- Step 5

```bash
# Confirm federated credentials
az ad app federated-credential list --id {deploymentClientId} -o table

# Confirm Azure role assignments
az role assignment list \
  --assignee ${DEPLOYMENT_SP_OBJECT_ID} \
  --scope "/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}" \
  -o table
```

---

## Step 6: Assign Application Roles to Users and Groups

Application roles control access to the gateway's Admin UI and management API. Roles are assigned via the Entra portal or CLI.

### 6.1 Assign Roles via CLI

```bash
# Get the Gateway API service principal object ID
GATEWAY_SP_OBJECT_ID=$(az ad sp show --id {gatewayApiClientId} --query "id" -o tsv)

# Get the role IDs
ADMIN_ROLE_ID=$(az ad app show --id {gatewayApiClientId} \
  --query "appRoles[?value=='Gateway.Administrator'].id" -o tsv)
OPERATOR_ROLE_ID=$(az ad app show --id {gatewayApiClientId} \
  --query "appRoles[?value=='Gateway.Operator'].id" -o tsv)
AUDITOR_ROLE_ID=$(az ad app show --id {gatewayApiClientId} \
  --query "appRoles[?value=='Gateway.Auditor'].id" -o tsv)
SUPPORT_ROLE_ID=$(az ad app show --id {gatewayApiClientId} \
  --query "appRoles[?value=='Gateway.SupportReader'].id" -o tsv)

# Assign Gateway.Administrator to a user
az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${GATEWAY_SP_OBJECT_ID}/appRoleAssignedTo" \
  --headers "Content-Type=application/json" \
  --body '{
    "principalId": "{userObjectId}",
    "resourceId": "'"${GATEWAY_SP_OBJECT_ID}"'",
    "appRoleId": "'"${ADMIN_ROLE_ID}"'"
  }'

# Assign Gateway.Operator to a group
az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${GATEWAY_SP_OBJECT_ID}/appRoleAssignedTo" \
  --headers "Content-Type=application/json" \
  --body '{
    "principalId": "{groupObjectId}",
    "resourceId": "'"${GATEWAY_SP_OBJECT_ID}"'",
    "appRoleId": "'"${OPERATOR_ROLE_ID}"'"
  }'
```

Repeat for `Gateway.Auditor` and `Gateway.SupportReader` roles as needed.

### 6.2 Assign Roles via Azure Portal

1. Navigate to **Microsoft Entra ID** > **Enterprise applications**.
2. Search for **A365 Gateway API**.
3. Select **Users and groups** > **Add user/group**.
4. Select the user or group, then select the role.
5. Click **Assign**.

### 6.3 Role Assignment Matrix (Recommended)

| Principal | Role | Justification |
|---|---|---|
| Gateway Operations Team (group) | `Gateway.Administrator` | Full control-plane access for initial setup and agent management |
| L2 Support Team (group) | `Gateway.Operator` | Enable/disable agents and view provisioning status; retry is Administrator-only |
| Security/Compliance Team (group) | `Gateway.Auditor` | Read-only access to audit logs and configuration history |
| L1 Support Team (group) | `Gateway.SupportReader` | Health and diagnostics monitoring with sensitive data redacted |

### Verification -- Step 6

```bash
# List all role assignments for the Gateway API
az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${GATEWAY_SP_OBJECT_ID}/appRoleAssignedTo" \
  --query "value[].{principalDisplayName:principalDisplayName, appRoleId:appRoleId, principalType:principalType}" \
  -o table
```

Verify that:
- At least one user or group has the `Gateway.Administrator` role.
- Each Gateway-provisioned child Agent ID service principal has Agent 365
  `Agent365.Observability.OtelWrite` and no Gateway application role.
- No users have the `ExternalAgent` role (it is application-only).
- No applications have user-type roles (`Gateway.Administrator`, etc.).

---

## Post-Setup Validation

### End-to-End Token Test -- Admin UI

1. Navigate to `https://{adminUiDomain}` in a browser.
2. Sign in with a user who has the `Gateway.Administrator` role.
3. After redirect, confirm the Blazor UI loads without authentication errors.
4. Open browser developer tools > Application > Cookies. Confirm an authentication cookie is present.

### End-to-End Test -- Gateway key ingress and Agent 365 egress

Workflow-v3 deployment/configuration and fail-closed recovery are verified. The
current canary is Active, matched Gateway activity and interaction returned HTTP
202, and Agent 365 OTLP accepted the sanitized export with HTTP 200. Final SQL/outbox
and queue evidence is recorded in the deployment status. Never run controller `Arm`
or the historical narrow rearm merely to repeat this proof. Preserve v2 `0/0/3` and v1 `0/0/2`
without receiving, peeking, settling, moving, or replaying any message.

`OpenAdmission` provides a 30--300 second operator window that starts after revision
readiness, a 60--300 second revision-rollout allowance, and a hard combined exposure
ceiling of 600 seconds enforced by `Provisioning__AdmissionExpiresAtUtc`. It does
enforce a one-registration boundary through the exact generated
`Provisioning__AuthorizedExternalAgentId`; retry remains unbound. After registration
closes, `OpenDelegatedCompletion` uses its own expiry and exact operation-ID binding.
Both controller windows close their respective gate in `finally`.

Require the worker to pause at 71%, the signed-in administrator OBO action to store a
durable Registry ID and reach 85%, and final worker verification to reach `Active`.
The registration response shows its Gateway API key once; transfer it without
logging or persisting the clear value in Gateway storage. Use the bounded helper in
[`agent365-observability-setup.md`](agent365-observability-setup.md#bounded-data-plane-proof)
to prove HTTP 403 for mismatched identity and HTTP 202 for matched activity and
interaction without rendering the key or bodies. Separately confirm the worker's
final `VerifyAgent365Connection` step used the blueprint's Gateway FIC and
`fmi_path=<child-agent-id>` to validate only the Agent 365 observability token. Record
only pass/fail, safe key ID, registration ID, and correlation ID. A sanitized OTLP
HTTP 200 response proves Agent 365 request acceptance only. Completion also requires
the controlled event to appear in Microsoft Defender `CloudAppEvents` after allowing
for service delay and verifying tenant licensing; do not claim telemetry landing
from HTTP 200 alone.

### Checklist

- [ ] Gateway API app registration created with 5 app roles
- [ ] Gateway API exposes `access_as_user` scope
- [ ] Admin UI app registration created with redirect URIs
- [ ] Admin UI has delegated permission to Gateway API scope
- [ ] Reusable typed Agent ID blueprint selected or created; no ordinary app was substituted
- [ ] Selected catalog row is Agent 365 compatible and the API/worker share the same reviewed manager configuration
- [ ] One deterministic Gateway-worker managed-identity FIC with exactly one `api://AzureADTokenExchange` audience verified on the blueprint; provisioning discovers and reuses it by GET and issues no duplicate FIC POST
- [ ] Child Agent ID has Agent 365 `Agent365.Observability.OtelWrite` and no Gateway role
- [ ] Only the exact eight workflow-v3 worker Graph application roles are present;
      both obsolete worker Registry roles are absent
- [ ] Gateway API app requests and has `AllPrincipals` admin consent for delegated
      `AgentRegistration.ReadWrite.All` and `AgentRegistration.Read.All`
- [ ] Gateway API app has one exact API-managed-identity FIC with tenant-v2 issuer,
      API MI principal/object ID subject, and sole `api://AzureADTokenExchange` audience
- [ ] Read-only `configure-workflow-v3-entra.ps1` reports no pending category after
      apply, and the independent provisioning preflight passes
- [ ] Workload identity federation configured for GitHub Actions
- [ ] At least one user/group assigned `Gateway.Administrator` role
- [ ] API managed identity has only the required typed-catalog `AgentIdentityBlueprint.Read.All` consent
- [ ] Worker-FIC Agent 365 token proof passed with `fmi_path=<child-agent-id>`
- [ ] Operation paused at 71%, delegated Administrator completion reached 85% with
      a durable service Registry ID, and final worker verification reached `Active`
- [ ] One-time Gateway key ingress canary passed for its bound registration
- [ ] Sanitized OTLP preserves child `gen_ai.agent.id` and blueprint
      `microsoft.a365.agent.blueprint.id`, omits `gen_ai.agent.type` and
      `microsoft.a365.agent.platform.id`, and the controlled event lands in Defender
      `CloudAppEvents`; HTTP 200 alone is recorded only as request acceptance

---

## Troubleshooting

| Issue | Cause | Resolution |
|---|---|---|
| `AADSTS700016: Application not found` | App registration does not exist or wrong tenant | Verify `{tenantId}` and `{clientId}` values |
| `AADSTS65001: User or admin has not consented` | Required delegated consent or application-role assignment is absent | Identify the exact client, resource, and permission. Follow its reviewed consent workflow; for the new worker system-assigned identity, use only the Step 4 app-role assignments and never `az ad app permission admin-consent`. |
| `AADSTS700054: response_type 'id_token' is not enabled` | ID token issuance not enabled | Run `az ad app update --id {adminUiClientId} --enable-id-token-issuance true` |
| Agent 365 token has no expected `roles` claim | The observability role isn't assigned to the child Agent ID | Verify only `Agent365.Observability.OtelWrite` from Step 3.3/4.3 |
| `403 AGENT_IDENTITY_MISMATCH` at runtime | The request's `externalAgentId` does not match the registration selected by its Gateway key | Correct the client mapping; never substitute a child/blueprint/Gateway ID or introduce a global key |
| FIC POST returned 201 but an immediate read is empty | Directory/read propagation is delayed; the mutation may already have succeeded | Preserve the returned FIC ID and perform only the bounded GET reconciliation. Never issue a second POST. If the exact resource cannot be verified, fail closed for manual intervention. |
| Agent 365 token exchange fails after metadata checks pass | Gateway FIC subject/issuer/audience, `fmi_path`, role assignment, or token scope is wrong | Treat metadata as partial evidence. Re-run from the exact worker without printing assertions/tokens; don't mark the Agent 365 connection complete. |
| `401 Unauthorized` from Graph API | Managed identity not assigned Graph permissions | Verify application permission grants and admin consent |
