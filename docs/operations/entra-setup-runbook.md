# Microsoft Entra ID Setup Runbook

This runbook covers the complete Microsoft Entra ID configuration required for the A365 Custom Gateway. It includes creating app registrations for the Gateway API, Admin UI, and external agents, configuring permissions, setting up workload identity federation for CI/CD, and assigning application roles to users and groups.

All commands use the Azure CLI (`az`) and Microsoft Graph CLI (`az ad`). PowerShell alternatives are noted where applicable.

---

## Prerequisites

| Requirement | Details |
|---|---|
| **Entra role** | Global Administrator or Application Administrator |
| **Azure CLI** | v2.60+ with `account` and `ad` extensions |
| **Microsoft Graph permissions** | `Application.ReadWrite.All`, `AppRoleAssignment.ReadWrite.All`, `Directory.Read.All` (for the operator running this runbook) |
| **Tenant ID** | `{tenantId}` |
| **Subscription** | `{subscriptionId}` |
| **Gateway API domain** | `{gatewayDomain}` (e.g., `gateway-api.{region}.azurecontainerapps.io`) |
| **Admin UI domain** | `{adminUiDomain}` (e.g., `gateway-admin.{region}.azurecontainerapps.io`) |
| **GitHub repository** | `{githubOrg}/{githubRepo}` (for workload identity federation) |

### Login

```bash
az login --tenant {tenantId}
az account set --subscription {subscriptionId}
```

---

## Step 1: Create the Gateway API App Registration

The Gateway API app registration exposes API scopes consumed by the Admin UI and external agents, and defines the five application roles used for authorization.

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

Define scopes that the Admin UI and external agents will request:

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
      "description": "Full control-plane access. Configure gateway, register and delete agents, start provisioning, rotate credentials, enable or disable integrations, assign operators and auditors.",
      "displayName": "Gateway Administrator",
      "isEnabled": true,
      "value": "Gateway.Administrator",
      "id": "'$(uuidgen)'"
    },
    {
      "allowedMemberTypes": ["User"],
      "description": "View agents, enable or disable agents, retry failed operations, view non-sensitive operational status.",
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

> **Important:** The first four roles use `"allowedMemberTypes": ["User"]` for interactive admin/operator/auditor/support access. The `ExternalAgent` role uses `"allowedMemberTypes": ["Application"]` because external agents authenticate via the client credentials flow (no signed-in user).

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
    "https://localhost:5001/signin-oidc" \
  --enable-id-token-issuance true \
  --query "appId" -o tsv
```

> Save the returned `appId` as `{adminUiClientId}`.

### 2.2 Add a Client Secret (Development Only)

For development environments, create a client secret. Production should use managed identity or certificate credentials.

```bash
az ad app credential reset \
  --id {adminUiClientId} \
  --display-name "Dev Secret" \
  --years 1 \
  --query "password" -o tsv
```

> **Warning:** Store this secret in Azure Key Vault immediately. Never commit it to source control, configuration files, or logs.

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

## Step 3: Create External Agent App Registrations

Each external AI agent requires its own Entra app registration. The gateway enforces a one-to-one binding between `externalClientId` (the Entra app's `appId`) and `externalAgentId` (the gateway registration ID). This prevents identity spoofing.

Repeat this step for each external agent.

### 3.1 Create the App Registration

```bash
az ad app create \
  --display-name "External Agent - {agentName}" \
  --sign-in-audience "AzureADMyOrg" \
  --query "appId" -o tsv
```

> Save the returned `appId` as `{externalAgentClientId}`. This value will be stored as `externalClientId` on the gateway's `AgentRegistration` entity.

### 3.2 Create a Service Principal

```bash
az ad sp create --id {externalAgentClientId}
```

### 3.3 Assign the ExternalAgent App Role

```bash
# Get the ExternalAgent role ID from the Gateway API
EXTERNAL_AGENT_ROLE_ID=$(az ad app show --id {gatewayApiClientId} \
  --query "appRoles[?value=='ExternalAgent'].id" -o tsv)

# Get the service principal object ID of the external agent
AGENT_SP_OBJECT_ID=$(az ad sp show --id {externalAgentClientId} --query "id" -o tsv)

# Get the service principal object ID of the Gateway API
GATEWAY_SP_OBJECT_ID=$(az ad sp show --id {gatewayApiClientId} --query "id" -o tsv)

# Assign the role
az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${GATEWAY_SP_OBJECT_ID}/appRoleAssignedTo" \
  --headers "Content-Type=application/json" \
  --body '{
    "principalId": "'"${AGENT_SP_OBJECT_ID}"'",
    "resourceId": "'"${GATEWAY_SP_OBJECT_ID}"'",
    "appRoleId": "'"${EXTERNAL_AGENT_ROLE_ID}"'"
  }'
```

### 3.4 Create a Certificate Credential (Production)

For production, use certificate credentials stored in Key Vault rather than client secrets.

```bash
# Generate a self-signed certificate in Key Vault
az keyvault certificate create \
  --vault-name {keyVaultName} \
  --name "ext-agent-{agentName}-cert" \
  --policy "$(az keyvault certificate get-default-policy)" \
  --validity 12

# Download the public key (PEM)
az keyvault certificate download \
  --vault-name {keyVaultName} \
  --name "ext-agent-{agentName}-cert" \
  --file ext-agent-{agentName}.pem \
  --encoding PEM

# Upload the certificate to the app registration
az ad app credential reset \
  --id {externalAgentClientId} \
  --cert @ext-agent-{agentName}.pem \
  --append
```

### 3.5 Create a Client Secret (Development Only)

```bash
az ad app credential reset \
  --id {externalAgentClientId} \
  --display-name "Dev Secret" \
  --years 1 \
  --query "password" -o tsv
```

> Store the secret in Key Vault. Provide it to the external agent operator through a secure channel.

### Verification -- Step 3

```bash
# Confirm app registration
az ad app show --id {externalAgentClientId} --query "{appId:appId, displayName:displayName}" -o table

# Confirm ExternalAgent role assignment
az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${GATEWAY_SP_OBJECT_ID}/appRoleAssignedTo" \
  --query "value[?principalId=='${AGENT_SP_OBJECT_ID}'].{appRoleId:appRoleId, principalDisplayName:principalDisplayName}" -o table

# Test client credential flow
curl -X POST "https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/token" \
  -d "client_id={externalAgentClientId}" \
  -d "client_secret={secret}" \
  -d "scope=api://{gatewayApiClientId}/.default" \
  -d "grant_type=client_credentials"
```

> The response should contain an `access_token` with the `ExternalAgent` role in the `roles` claim.

---

## Step 4: Grant Admin Consent for Microsoft Graph Permissions

The Gateway API's managed identity (or workload identity) needs Microsoft Graph permissions for provisioning operations. The Admin UI needs `Directory.Read.All` for user and group lookup.

### 4.1 Gateway API -- Graph Permissions for Provisioning

These permissions are required by the provisioning worker (running as managed identity). They are configured via Azure role assignments, not app registration API permissions, when using managed identity. However, the following Graph application permissions are needed if the worker uses app-based auth:

```bash
# Microsoft Graph application ID: 00000003-0000-0000-c000-000000000000

# Directory.Read.All - For user/group lookup
az ad app permission add \
  --id {gatewayApiClientId} \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions "7ab1d382-f21e-4acd-a863-ba3e13f7da61=Role"

# Application.ReadWrite.OwnedBy - For creating app registrations during provisioning
az ad app permission add \
  --id {gatewayApiClientId} \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions "18a4783c-866b-4cc7-a460-3d5e5662c884=Role"
```

### 4.2 Grant Admin Consent

Admin consent is required for application permissions. This requires Global Administrator or Privileged Role Administrator.

```bash
# Grant admin consent for the Gateway API
az ad app permission admin-consent --id {gatewayApiClientId}

# Grant admin consent for the Admin UI (if delegated permissions were added)
az ad app permission admin-consent --id {adminUiClientId}
```

### 4.3 Verify Consent Status

```bash
# Check granted permissions for Gateway API
az ad app permission list-grants \
  --filter "clientId eq '$(az ad sp show --id {gatewayApiClientId} --query id -o tsv)'" \
  -o table

# Alternatively, check via the service principal
az ad sp show --id {gatewayApiClientId} \
  --query "appRoleAssignments[].{resourceDisplayName:resourceDisplayName, appRoleId:appRoleId}" -o table
```

### Verification -- Step 4

1. In the Azure Portal, navigate to **Microsoft Entra ID** > **App registrations** > **A365 Gateway API** > **API permissions**.
2. Confirm all permissions show **Granted for {tenantName}** in the Status column.
3. There should be no "Not granted" entries for application permissions.

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
| L2 Support Team (group) | `Gateway.Operator` | Enable/disable agents and retry failed provisioning |
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
- Each external agent's service principal has the `ExternalAgent` role.
- No users have the `ExternalAgent` role (it is application-only).
- No applications have user-type roles (`Gateway.Administrator`, etc.).

---

## Post-Setup Validation

### End-to-End Token Test -- Admin UI

1. Navigate to `https://{adminUiDomain}` in a browser.
2. Sign in with a user who has the `Gateway.Administrator` role.
3. After redirect, confirm the Blazor UI loads without authentication errors.
4. Open browser developer tools > Application > Cookies. Confirm an authentication cookie is present.

### End-to-End Token Test -- External Agent

```bash
# Acquire a token using client credentials
TOKEN=$(curl -s -X POST "https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/token" \
  -d "client_id={externalAgentClientId}" \
  -d "client_secret={secret}" \
  -d "scope=api://{gatewayApiClientId}/.default" \
  -d "grant_type=client_credentials" | jq -r '.access_token')

# Decode the token (inspect claims)
echo $TOKEN | cut -d'.' -f2 | base64 -d 2>/dev/null | jq .

# Verify the token contains the ExternalAgent role
echo $TOKEN | cut -d'.' -f2 | base64 -d 2>/dev/null | jq '.roles'
# Expected: ["ExternalAgent"]

# Call the gateway health endpoint
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://{gatewayDomain}/health/checks" | jq .
```

### Checklist

- [ ] Gateway API app registration created with 5 app roles
- [ ] Gateway API exposes `access_as_user` scope
- [ ] Admin UI app registration created with redirect URIs
- [ ] Admin UI has delegated permission to Gateway API scope
- [ ] At least one external agent app registration created
- [ ] External agent has `ExternalAgent` role assigned
- [ ] Admin consent granted for all application permissions
- [ ] Workload identity federation configured for GitHub Actions
- [ ] At least one user/group assigned `Gateway.Administrator` role
- [ ] End-to-end token acquisition tested for both Admin UI and external agent flows

---

## Troubleshooting

| Issue | Cause | Resolution |
|---|---|---|
| `AADSTS700016: Application not found` | App registration does not exist or wrong tenant | Verify `{tenantId}` and `{clientId}` values |
| `AADSTS65001: User or admin has not consented` | Admin consent not granted | Run `az ad app permission admin-consent` |
| `AADSTS700054: response_type 'id_token' is not enabled` | ID token issuance not enabled | Run `az ad app update --id {adminUiClientId} --enable-id-token-issuance true` |
| Token has no `roles` claim | App role not assigned to service principal | Verify role assignment in Step 3.3 or Step 6 |
| `403 AGENT_IDENTITY_MISMATCH` at runtime | `externalClientId` on AgentRegistration does not match the token's `appid`/`azp` | Verify the correct `appId` was stored during agent registration |
| `401 Unauthorized` from Graph API | Managed identity not assigned Graph permissions | Verify application permission grants and admin consent |
