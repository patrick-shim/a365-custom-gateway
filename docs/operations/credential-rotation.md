# Credential Rotation Runbook

This runbook covers the credential rotation strategy for all components of the A365 Custom Gateway. It documents which credentials require rotation, which are Azure-managed, rotation procedures, and audit trail requirements.

A key design principle of the gateway is that managed identity is used wherever possible, eliminating the need for credential rotation in most runtime scenarios.

---

## Prerequisites

| Requirement | Details |
|---|---|
| **Entra role** | Application Administrator (for app registration credential rotation) |
| **Azure role** | Key Vault Secrets Officer and Key Vault Certificates Officer on `{keyVaultName}` |
| **Azure CLI** | v2.60+ |
| **PowerShell** | 7.2+ (for Microsoft.Graph PowerShell SDK) |
| **Resource group** | `{resourceGroup}` |
| **Key Vault** | `{keyVaultName}` |

### Login

```bash
az login --tenant {tenantId}
az account set --subscription {subscriptionId}
```

---

## Credential Inventory

### Credentials That Do NOT Require Rotation

| Component | Credential Type | Reason |
|---|---|---|
| Gateway API --> Azure SQL | Managed identity (system-assigned) | Azure-managed. Token lifecycle handled by the platform. No shared secret. |
| Gateway API --> Service Bus | Managed identity (system-assigned) | Azure-managed. No connection strings stored or used. |
| Gateway API --> Key Vault | Managed identity + RBAC | Azure-managed. Key Vault access is via RBAC role assignments, not access policies or secrets. |
| Gateway API --> Application Insights | Managed identity + connection string | Connection string contains instrumentation key (not a secret -- used for routing only). |
| Worker --> Azure SQL | Managed identity (system-assigned) | Same as above. |
| Worker --> Service Bus | Managed identity (system-assigned) | Same as above. |
| Worker --> Key Vault | Managed identity + RBAC | Same as above. |
| Worker --> Microsoft Graph | Managed identity | Application permissions granted to the managed identity's service principal. No client secret. |
| Worker --> Purview APIs | Managed identity | Application permissions granted to the managed identity's service principal. |

### Credentials That DO Require Rotation

| Component | Credential Type | Rotation Frequency | Method |
|---|---|---|---|
| External agent app registrations | Client secret or certificate | Certificates: annually. Secrets: 6 months (dev), 12 months (prod). | Key Vault managed rotation or manual (see Section 2) |
| Admin UI app registration (dev) | Client secret | 6 months | Manual (see Section 3) |
| GitHub Actions deployment | Workload identity federation | No rotation needed | OIDC -- no shared secret |
| SQL Server admin password | Password | Annually or on-demand | Emergency procedure only (see Section 4) |

---

## 1. Managed Identity -- No Rotation Required

The gateway uses system-assigned managed identity on both Container Apps (API and Worker). Azure manages the credential lifecycle automatically:

- Token issuance, refresh, and revocation are handled by the Azure platform.
- There are no client secrets, certificates, or connection strings to rotate.
- If a managed identity is compromised (extremely rare), disable and re-enable the system-assigned identity on the Container App.

### Verify Managed Identity Configuration

```bash
# Verify system-assigned managed identity is enabled on the API Container App
az containerapp show \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --query "identity.{type:type, principalId:principalId, tenantId:tenantId}" -o table

# Verify system-assigned managed identity is enabled on the Worker Container App
az containerapp show \
  --name {workerContainerAppName} \
  --resource-group {resourceGroup} \
  --query "identity.{type:type, principalId:principalId, tenantId:tenantId}" -o table
```

### Emergency: Re-create Managed Identity

In the unlikely event that a managed identity is compromised:

```bash
# Disable system-assigned identity (revokes all tokens immediately)
az containerapp identity remove \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --system-assigned

# Re-enable system-assigned identity (creates a new identity with a new principal)
az containerapp identity assign \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --system-assigned
```

> **Warning:** After re-creating the managed identity, you must re-grant all RBAC role assignments and Graph API permissions to the new principal. See the Entra Setup Runbook and Purview Setup Runbook.

---

## 2. External Agent Credentials

Each external agent has its own Entra app registration with either a client secret (development) or certificate (production). These are the primary credentials requiring rotation.

### 2.1 Key Vault Managed Rotation (Recommended for Production)

Key Vault can automate certificate rotation using rotation policies:

```bash
# Set a rotation policy on an external agent certificate
az keyvault certificate set-attributes \
  --vault-name {keyVaultName} \
  --name "ext-agent-{agentName}-cert" \
  --policy "$(cat <<'EOF'
{
  "issuerParameters": {
    "name": "Self"
  },
  "keyProperties": {
    "exportable": true,
    "keySize": 2048,
    "keyType": "RSA",
    "reuseKey": false
  },
  "lifetimeActions": [
    {
      "action": { "actionType": "AutoRenew" },
      "trigger": { "daysBeforeExpiry": 30 }
    },
    {
      "action": { "actionType": "EmailContacts" },
      "trigger": { "daysBeforeExpiry": 60 }
    }
  ],
  "x509CertificateProperties": {
    "validityInMonths": 12,
    "subject": "CN=ext-agent-{agentName}"
  }
}
EOF
)"
```

> **Note:** Key Vault auto-renew creates a new certificate version. The gateway must be notified to update the app registration with the new certificate. This is handled by the Event Grid integration below.

### 2.2 Event Grid Integration for Automatic Credential Update

Set up an Event Grid subscription to trigger credential update when Key Vault rotates a certificate:

```bash
# Create an Event Grid subscription for certificate near-expiry events
az eventgrid event-subscription create \
  --name "cert-rotation-notification" \
  --source-resource-id "/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.KeyVault/vaults/{keyVaultName}" \
  --included-event-types "Microsoft.KeyVault.CertificateNearExpiry" "Microsoft.KeyVault.CertificateNewVersionCreated" \
  --endpoint-type webhook \
  --endpoint "https://{gatewayDomain}/api/v1/system/credential-rotation-webhook"
```

### 2.3 Manual Certificate Rotation (Zero-Downtime)

For manual rotation, use an overlap window where both old and new credentials are valid:

```bash
# Step 1: Generate a new certificate in Key Vault
az keyvault certificate create \
  --vault-name {keyVaultName} \
  --name "ext-agent-{agentName}-cert-v2" \
  --policy "$(az keyvault certificate get-default-policy)" \
  --validity 12

# Step 2: Download the new certificate's public key
az keyvault certificate download \
  --vault-name {keyVaultName} \
  --name "ext-agent-{agentName}-cert-v2" \
  --file ext-agent-{agentName}-v2.pem \
  --encoding PEM

# Step 3: Add the new certificate to the app registration (append, do not replace)
az ad app credential reset \
  --id {externalAgentClientId} \
  --cert @ext-agent-{agentName}-v2.pem \
  --append

# Step 4: Verify both certificates are active on the app registration
az ad app credential list --id {externalAgentClientId} -o table

# Step 5: Notify the external agent operator to switch to the new certificate
# (provide the new certificate via a secure channel)

# Step 6: After the agent operator confirms they are using the new certificate,
# remove the old certificate
OLD_KEY_ID=$(az ad app credential list --id {externalAgentClientId} \
  --query "[?endDateTime < '$(date -u -d '+30 days' '+%Y-%m-%dT%H:%M:%SZ')'].keyId" -o tsv)

az ad app credential delete \
  --id {externalAgentClientId} \
  --key-id ${OLD_KEY_ID}

# Step 7: Update the gateway's credential reference
curl -X POST "https://{gatewayDomain}/api/v1/agents/{agentId}/credentials:rotate" \
  -H "Authorization: Bearer {adminToken}" \
  -H "Content-Type: application/json" \
  -d '{
    "credentialType": "Certificate",
    "keyVaultSecretName": "ext-agent-{agentName}-cert-v2"
  }'
```

### 2.4 Manual Client Secret Rotation (Development Only)

```bash
# Step 1: Create a new secret (overlap -- both old and new are valid)
NEW_SECRET=$(az ad app credential reset \
  --id {externalAgentClientId} \
  --display-name "Rotated $(date +%Y%m%d)" \
  --years 1 \
  --append \
  --query "password" -o tsv)

# Step 2: Store the new secret in Key Vault
az keyvault secret set \
  --vault-name {keyVaultName} \
  --name "ext-agent-{agentName}-secret" \
  --value "${NEW_SECRET}"

# Step 3: Notify the external agent operator of the new secret
# (via secure channel -- NOT email, NOT chat logs)

# Step 4: After confirmation, remove the old secret
OLD_KEY_ID=$(az ad app credential list --id {externalAgentClientId} \
  --query "sort_by(@, &endDateTime)[0].keyId" -o tsv)

az ad app credential delete \
  --id {externalAgentClientId} \
  --key-id ${OLD_KEY_ID}
```

### 2.5 Notification Workflow Before Expiration

Set up proactive notifications before credentials expire:

```bash
# List credentials expiring within 30 days for all external agents
az ad app credential list --id {externalAgentClientId} \
  --query "[?endDateTime < '$(date -u -d '+30 days' '+%Y-%m-%dT%H:%M:%SZ')'].{keyId:keyId, type:type, endDateTime:endDateTime}" -o table
```

The gateway should run a scheduled job (via the Worker) that:

1. Queries all `AgentCredentialReference` records from the database.
2. Checks expiration dates of referenced Key Vault certificates/secrets.
3. Sends alerts at 60 days, 30 days, and 7 days before expiration.
4. Logs an `AuditEvent` of type `CredentialExpiringWarning`.

```kusto
// KQL: Monitor credential expiration warnings
customEvents
| where name == "CredentialExpiringWarning"
| project timestamp,
  tostring(customDimensions["agentId"]),
  tostring(customDimensions["credentialType"]),
  tostring(customDimensions["expirationDate"]),
  tostring(customDimensions["daysUntilExpiry"])
| order by timestamp desc
```

---

## 3. Admin UI App Registration (Development Only)

The Admin UI uses OIDC interactive sign-in. In production, managed identity handles the backend-to-API communication. In development, a client secret is used.

### 3.1 Rotate the Admin UI Client Secret

```bash
# Step 1: Create a new secret
NEW_UI_SECRET=$(az ad app credential reset \
  --id {adminUiClientId} \
  --display-name "Rotated $(date +%Y%m%d)" \
  --years 1 \
  --append \
  --query "password" -o tsv)

# Step 2: Store in Key Vault
az keyvault secret set \
  --vault-name {keyVaultName} \
  --name "adminui-client-secret" \
  --value "${NEW_UI_SECRET}"

# Step 3: Update the Container App environment variable
az containerapp update \
  --name {adminUiContainerAppName} \
  --resource-group {resourceGroup} \
  --set-env-vars "AzureAd__ClientSecret=secretref:adminui-client-secret"

# Step 4: Remove the old secret from the app registration
OLD_KEY_ID=$(az ad app credential list --id {adminUiClientId} \
  --query "sort_by(@, &endDateTime)[0].keyId" -o tsv)

az ad app credential delete \
  --id {adminUiClientId} \
  --key-id ${OLD_KEY_ID}
```

---

## 4. SQL Server Admin Password

The SQL Server admin password is used only during initial deployment and emergency administrative access. At runtime, the gateway uses managed identity exclusively -- there is no runtime dependency on the SQL admin password.

### 4.1 When to Rotate

- After initial setup (rotate from the deployment-generated password).
- If the password is suspected to be compromised.
- Annually, per organizational security policy.

### 4.2 Impact Assessment

| Scenario | Impact |
|---|---|
| Runtime (gateway API and worker) | **No impact.** Managed identity authentication is unaffected by admin password changes. |
| CI/CD deployments (EF Core migrations) | **Potential impact** if migrations use SQL auth instead of managed identity. Verify the migration connection string. |
| Emergency manual database access | Must use the new password for SQL auth connections. |

### 4.3 Rotation Procedure

```bash
# Step 1: Generate a new password (32+ characters, mixed case, numbers, symbols)
NEW_SQL_PASSWORD=$(openssl rand -base64 32)

# Step 2: Store the new password in Key Vault
az keyvault secret set \
  --vault-name {keyVaultName} \
  --name "sql-admin-password" \
  --value "${NEW_SQL_PASSWORD}"

# Step 3: Update the SQL Server admin password
az sql server update \
  --name {sqlServerName} \
  --resource-group {resourceGroup} \
  --admin-password "${NEW_SQL_PASSWORD}"

# Step 4: Verify connectivity with the new password
az sql query \
  --server {sqlServerName} \
  --name {databaseName} \
  --resource-group {resourceGroup} \
  --query "SELECT 1 AS ConnectionTest" \
  --admin-user {adminUsername} \
  --admin-password "${NEW_SQL_PASSWORD}"

# Step 5: Clear the password from the shell history
history -d $(history 1 | awk '{print $1}')
unset NEW_SQL_PASSWORD
```

---

## 5. Credentials Not Applicable (Managed Identity)

The following components use managed identity exclusively. There are no connection strings, shared access keys, or credentials to rotate.

### 5.1 Service Bus

The gateway accesses Service Bus via managed identity with Azure RBAC roles:

| Container App | RBAC Role | Scope |
|---|---|---|
| Gateway API | Azure Service Bus Data Sender | `gateway-provisioning`, `gateway-observability-export`, `gateway-reconciliation` queues |
| Provisioning Worker | Azure Service Bus Data Receiver | All queues |

```bash
# Verify role assignments
az role assignment list \
  --scope "/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.ServiceBus/namespaces/{serviceBusNamespace}" \
  --query "[].{principalName:principalName, roleDefinitionName:roleDefinitionName}" -o table
```

> There are no Service Bus connection strings configured anywhere in the gateway. If you find a connection string, this is a configuration error that should be corrected.

### 5.2 Key Vault

The gateway accesses Key Vault via managed identity with RBAC roles:

| Container App | RBAC Role | Purpose |
|---|---|---|
| Gateway API | Key Vault Secrets User | Read agent credential references |
| Provisioning Worker | Key Vault Secrets Officer | Read and write agent credential references |
| Provisioning Worker | Key Vault Certificates Officer | Create and manage agent certificates |

```bash
# Verify role assignments
az role assignment list \
  --scope "/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.KeyVault/vaults/{keyVaultName}" \
  --query "[].{principalName:principalName, roleDefinitionName:roleDefinitionName}" -o table
```

---

## 6. Rotation Audit Trail

All credential rotation events are recorded in two places:

### 6.1 Key Vault Diagnostic Logs

Key Vault diagnostic settings should be configured to send audit logs to Log Analytics:

```bash
# Verify diagnostic settings
az monitor diagnostic-settings list \
  --resource "/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.KeyVault/vaults/{keyVaultName}" \
  --query "[].{name:name, logs:logs[].{category:category, enabled:enabled}}" -o json
```

```kusto
// KQL: Query Key Vault audit logs for rotation events
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where OperationName in ("SecretSet", "CertificateCreate", "SecretGet", "CertificateGet")
| project TimeGenerated, OperationName, ResultType, CallerIPAddress, id_s
| order by TimeGenerated desc
| take 50
```

### 6.2 Gateway Audit Events

The gateway records credential rotation in its `AuditEvents` table:

```kusto
// KQL: Query gateway audit events for credential changes
customEvents
| where name == "AuditEvent"
| where customDimensions["eventType"] in (
  "CredentialRotated",
  "CredentialCreated",
  "CredentialDeleted",
  "CredentialExpiringWarning"
)
| project timestamp,
  tostring(customDimensions["eventType"]),
  tostring(customDimensions["agentId"]),
  tostring(customDimensions["performedByObjectId"]),
  tostring(customDimensions["credentialType"])
| order by timestamp desc
```

---

## Rotation Schedule Summary

| Credential | Rotation Frequency | Owner | Automated? |
|---|---|---|---|
| External agent certificates | Annually | Gateway Administrator | Yes (Key Vault rotation policy) |
| External agent client secrets (dev) | Every 6 months | Gateway Administrator | No (manual) |
| Admin UI client secret (dev) | Every 6 months | Gateway Administrator | No (manual) |
| SQL admin password | Annually or on-demand | Infrastructure team | No (emergency only) |
| GitHub Actions OIDC | Never (no shared secret) | DevOps | N/A |
| Managed identity tokens | Automatic (Azure-managed) | Azure platform | Yes (platform) |
| Service Bus connection strings | N/A (managed identity) | N/A | N/A |
| Key Vault access credentials | N/A (managed identity + RBAC) | N/A | N/A |

---

## Troubleshooting

| Issue | Cause | Resolution |
|---|---|---|
| External agent gets `401 Unauthorized` after rotation | Agent is still using the old credential | Verify the agent operator has updated to the new credential |
| `403 Forbidden` from Key Vault after managed identity re-creation | RBAC role assignments point to old principal ID | Re-assign RBAC roles to the new managed identity principal |
| Key Vault certificate auto-renewal did not update the app registration | Event Grid webhook not configured or not processing | Check Event Grid delivery status; manually update the app registration |
| SQL admin password change causes CI/CD failure | Migration step uses SQL auth with the old password | Update the CI/CD secret/variable with the new password |
| Key Vault audit logs not appearing | Diagnostic settings not configured | Enable Key Vault diagnostic settings with Log Analytics destination |
