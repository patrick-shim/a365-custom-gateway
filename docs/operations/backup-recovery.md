# Backup and Recovery Runbook

This runbook covers backup configuration, recovery procedures, and disaster recovery planning for all stateful components of the A365 Custom Gateway: Azure SQL Database, Azure Key Vault, Azure Service Bus, and Azure Blob Storage.

---

## Prerequisites

| Requirement | Details |
|---|---|
| **Azure role** | Contributor on the resource group (for restore operations), Key Vault Administrator (for secret recovery), SQL Server Contributor (for database restore) |
| **Azure CLI** | v2.60+ |
| **EF Core tools** | `dotnet-ef` tool installed (for post-restore migration checks) |
| **Resource group** | `{resourceGroup}` |
| **Subscription** | `{subscriptionId}` |

### Login

```bash
az login --tenant {tenantId}
az account set --subscription {subscriptionId}
```

---

## 1. Azure SQL Database

Azure SQL Database provides automatic backups. The gateway relies on these backups for point-in-time recovery. No manual backup scheduling is required.

### 1.1 Automatic Backup Configuration

| Setting | Development | Staging | Production |
|---|---|---|---|
| **Backup type** | Full + differential + log | Full + differential + log | Full + differential + log |
| **Short-term retention** | 7 days | 14 days | 35 days |
| **Long-term retention (weekly)** | None | 4 weeks | 12 weeks |
| **Long-term retention (monthly)** | None | None | 12 months |
| **Long-term retention (yearly)** | None | None | 5 years |
| **Backup storage redundancy** | Locally redundant (LRS) | Zone-redundant (ZRS) | Geo-redundant (GRS) |

### 1.2 Configure Short-Term Retention

```bash
# Set retention period (number of days, 1-35)
az sql db str-policy set \
  --server {sqlServerName} \
  --name {databaseName} \
  --resource-group {resourceGroup} \
  --retention-days 35 \
  --diffbackup-hours 12
```

### 1.3 Configure Long-Term Retention

```bash
# Configure long-term retention policy (production)
az sql db ltr-policy set \
  --server {sqlServerName} \
  --name {databaseName} \
  --resource-group {resourceGroup} \
  --weekly-retention P12W \
  --monthly-retention P12M \
  --yearly-retention P5Y \
  --week-of-year 1
```

### 1.4 Verify Backup Configuration

```bash
# Check short-term retention policy
az sql db str-policy show \
  --server {sqlServerName} \
  --name {databaseName} \
  --resource-group {resourceGroup} -o table

# Check long-term retention policy
az sql db ltr-policy show \
  --server {sqlServerName} \
  --name {databaseName} \
  --resource-group {resourceGroup} -o table

# List available backups
az sql db ltr-backup list \
  --location {region} \
  --server {sqlServerName} \
  --database {databaseName} -o table
```

### 1.5 Point-in-Time Restore Procedure

Use this procedure to restore the database to a specific point in time (within the retention period).

#### Via Azure CLI

```bash
# Step 1: Determine the restore point (UTC timestamp)
RESTORE_POINT="2026-08-23T10:30:00Z"

# Step 2: Restore to a new database (do NOT overwrite the existing database)
az sql db restore \
  --server {sqlServerName} \
  --name {databaseName}-restored \
  --resource-group {resourceGroup} \
  --dest-name {databaseName}-restored-$(date +%Y%m%d%H%M) \
  --time ${RESTORE_POINT}
```

#### Via Azure Portal

1. Navigate to **Azure SQL Database** > `{databaseName}`.
2. Click **Restore** in the toolbar.
3. Select **Point in time** and choose the desired timestamp.
4. Enter a new database name (e.g., `{databaseName}-restored-20260823`).
5. Click **Review + create** > **Create**.

#### Step 3: Validate the Restored Database

```bash
# Connect to the restored database and verify data
az sql query \
  --server {sqlServerName} \
  --name {databaseName}-restored-20260823 \
  --resource-group {resourceGroup} \
  --query "SELECT COUNT(*) AS AgentCount FROM AgentRegistrations WHERE IsDeleted = 0"
```

### 1.6 Post-Restore Steps

After restoring to a new database:

1. **Verify managed identity access:**

```bash
# The restored database inherits the server-level managed identity configuration.
# Verify the gateway's managed identity can connect:
az sql db show \
  --server {sqlServerName} \
  --name {databaseName}-restored-20260823 \
  --resource-group {resourceGroup} \
  --query "status" -o tsv
```

2. **Check EF Core migration state:**

```bash
# List applied migrations on the restored database
"C:\Program Files\dotnet\dotnet.exe" ef migrations list \
  --project src/Gateway.Infrastructure \
  --startup-project src/Gateway.Api \
  --connection "Server={sqlServerName}.database.windows.net;Database={databaseName}-restored-20260823;Authentication=Active Directory Default;"
```

3. **Apply any pending migrations** (if the restore point predates the latest migration):

```bash
"C:\Program Files\dotnet\dotnet.exe" ef database update \
  --project src/Gateway.Infrastructure \
  --startup-project src/Gateway.Api \
  --connection "Server={sqlServerName}.database.windows.net;Database={databaseName}-restored-20260823;Authentication=Active Directory Default;"
```

4. **Swap databases** (if the restored database should become the primary):

```bash
# Option A: Update the Container App environment variable to point to the new database
az containerapp update \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --set-env-vars "ConnectionStrings__GatewayDb=Server={sqlServerName}.database.windows.net;Database={databaseName}-restored-20260823;Authentication=Active Directory Default;"

# Option B: Rename databases (requires no active connections)
# Step 1: Rename the current database
az sql db rename \
  --server {sqlServerName} \
  --name {databaseName} \
  --resource-group {resourceGroup} \
  --new-name {databaseName}-old-$(date +%Y%m%d)

# Step 2: Rename the restored database to the original name
az sql db rename \
  --server {sqlServerName} \
  --name {databaseName}-restored-20260823 \
  --resource-group {resourceGroup} \
  --new-name {databaseName}
```

5. **Restart the Container Apps** to pick up the new database connection:

```bash
az containerapp revision restart \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --revision {currentRevision}

az containerapp revision restart \
  --name {workerContainerAppName} \
  --resource-group {resourceGroup} \
  --revision {currentRevision}
```

### 1.7 Long-Term Retention Restore

```bash
# List available LTR backups
az sql db ltr-backup list \
  --location {region} \
  --server {sqlServerName} \
  --database {databaseName} \
  --query "[].{backupName:name, backupTime:properties.backupTime}" -o table

# Restore from an LTR backup
az sql db ltr-backup restore \
  --backup-id "{ltrBackupResourceId}" \
  --dest-database {databaseName}-ltr-restored \
  --dest-server {sqlServerName} \
  --dest-resource-group {resourceGroup}
```

---

## 2. Azure Key Vault

Azure Key Vault provides soft-delete and purge protection. These features ensure that accidentally deleted secrets, keys, and certificates can be recovered.

### 2.1 Soft-Delete and Purge Protection Configuration

| Setting | Development | Staging | Production |
|---|---|---|---|
| **Soft-delete** | Enabled (required) | Enabled (required) | Enabled (required) |
| **Soft-delete retention** | 7 days | 30 days | 90 days |
| **Purge protection** | Disabled | Enabled | Enabled |

> **Note:** Soft-delete is enabled by default on all new Key Vaults and cannot be disabled. Purge protection, once enabled, cannot be disabled.

### 2.2 Verify Key Vault Protection Settings

```bash
az keyvault show \
  --name {keyVaultName} \
  --resource-group {resourceGroup} \
  --query "{softDeleteEnabled:properties.enableSoftDelete, softDeleteRetentionDays:properties.softDeleteRetentionInDays, purgeProtectionEnabled:properties.enablePurgeProtection}" -o table
```

### 2.3 Enable Purge Protection (if not already enabled)

```bash
# Enable purge protection (one-way operation -- cannot be disabled)
az keyvault update \
  --name {keyVaultName} \
  --resource-group {resourceGroup} \
  --enable-purge-protection true
```

### 2.4 Recover a Deleted Secret

```bash
# List deleted secrets
az keyvault secret list-deleted \
  --vault-name {keyVaultName} \
  --query "[].{name:name, deletedDate:deletedDate, scheduledPurgeDate:scheduledPurgeDate}" -o table

# Recover a specific deleted secret
az keyvault secret recover \
  --vault-name {keyVaultName} \
  --name {secretName}

# Verify recovery
az keyvault secret show \
  --vault-name {keyVaultName} \
  --name {secretName} \
  --query "{name:name, enabled:attributes.enabled, created:attributes.created}" -o table
```

### 2.5 Recover a Deleted Certificate

```bash
# List deleted certificates
az keyvault certificate list-deleted \
  --vault-name {keyVaultName} -o table

# Recover a deleted certificate
az keyvault certificate recover \
  --vault-name {keyVaultName} \
  --name {certificateName}
```

### 2.6 Recover a Deleted Key

```bash
# List deleted keys
az keyvault key list-deleted \
  --vault-name {keyVaultName} -o table

# Recover a deleted key
az keyvault key recover \
  --vault-name {keyVaultName} \
  --name {keyName}
```

### 2.7 Key Vault Backup and Restore

For critical secrets, create manual backups that can be restored to any Key Vault in the same subscription:

```bash
# Backup a secret
az keyvault secret backup \
  --vault-name {keyVaultName} \
  --name {secretName} \
  --file {secretName}-backup.blob

# Restore a secret (to any vault in the same subscription)
az keyvault secret restore \
  --vault-name {targetKeyVaultName} \
  --file {secretName}-backup.blob
```

> **Warning:** Backup files contain the secret material. Store them securely and delete after restore.

---

## 3. Azure Service Bus

Azure Service Bus does not provide traditional backup/restore. Recovery focuses on dead-letter queue (DLQ) management and message replay.

### 3.1 Dead-Letter Queue Monitoring

The gateway uses the following Service Bus queues:

| Queue Name | Purpose | DLQ Threshold (Alert) |
|---|---|---|
| `gateway-provisioning` | Provisioning job messages | 5 messages |
| `gateway-observability-export` | Agent 365 telemetry export | 50 messages |
| `gateway-reconciliation` | Reconciliation job triggers | 3 messages |

```bash
# Check DLQ depth for all queues
for QUEUE in gateway-provisioning gateway-observability-export gateway-reconciliation; do
  DLQ_COUNT=$(az servicebus queue show \
    --namespace-name {serviceBusNamespace} \
    --resource-group {resourceGroup} \
    --name ${QUEUE} \
    --query "countDetails.deadLetterMessageCount" -o tsv)
  echo "${QUEUE}: ${DLQ_COUNT} dead-lettered messages"
done
```

### 3.2 DLQ Message Inspection

```bash
# Peek at dead-lettered messages (non-destructive)
az servicebus queue message peek \
  --namespace-name {serviceBusNamespace} \
  --resource-group {resourceGroup} \
  --queue-name gateway-provisioning \
  --max-count 10 \
  --dead-letter
```

### 3.3 DLQ Message Resubmission

To replay dead-lettered messages after fixing the root cause:

```bash
# Receive (destructive) from the DLQ and re-send to the main queue
# This requires a custom script or the Service Bus Explorer tool

# Option 1: Use Azure Service Bus Explorer (GUI tool)
# Download from: https://github.com/paolosalvatori/ServiceBusExplorer

# Option 2: Use az servicebus CLI to receive and resend
# Receive a message from the DLQ
az servicebus queue message receive \
  --namespace-name {serviceBusNamespace} \
  --resource-group {resourceGroup} \
  --queue-name gateway-provisioning \
  --dead-letter

# Re-send the message to the main queue
az servicebus queue message send \
  --namespace-name {serviceBusNamespace} \
  --resource-group {resourceGroup} \
  --queue-name gateway-provisioning \
  --body "{messageBody}"
```

### 3.4 DLQ Purge (Discard Messages)

If dead-lettered messages are no longer relevant (e.g., the associated provisioning job has been manually resolved):

```bash
# Receive and discard all DLQ messages (destructive)
while true; do
  RESULT=$(az servicebus queue message receive \
    --namespace-name {serviceBusNamespace} \
    --resource-group {resourceGroup} \
    --queue-name gateway-provisioning \
    --dead-letter \
    --max-wait-time 5 2>/dev/null)
  if [ -z "$RESULT" ] || [ "$RESULT" = "null" ]; then
    echo "DLQ is empty."
    break
  fi
  echo "Discarded message."
done
```

> **Warning:** This permanently discards messages. Ensure the root cause has been resolved and the messages are no longer needed.

---

## 4. Azure Blob Storage

Azure Blob Storage is used by the gateway for storing large payloads, export files, and temporary processing artifacts.

### 4.1 Soft-Delete Configuration

| Setting | Development | Staging | Production |
|---|---|---|---|
| **Blob soft-delete** | 7 days | 14 days | 30 days |
| **Container soft-delete** | 7 days | 14 days | 30 days |
| **Versioning** | Disabled | Enabled | Enabled |
| **Point-in-time restore** | Disabled | Disabled | Enabled (7 days) |
| **Redundancy** | LRS | ZRS | Standard_GRS |

```bash
# Configure soft-delete retention
az storage account blob-service-properties update \
  --account-name {storageAccountName} \
  --resource-group {resourceGroup} \
  --enable-delete-retention true \
  --delete-retention-days 30

# Configure container soft-delete
az storage account blob-service-properties update \
  --account-name {storageAccountName} \
  --resource-group {resourceGroup} \
  --enable-container-delete-retention true \
  --container-delete-retention-days 30

# Enable versioning (staging/production)
az storage account blob-service-properties update \
  --account-name {storageAccountName} \
  --resource-group {resourceGroup} \
  --enable-versioning true
```

### 4.2 Point-in-Time Restore (Production)

Point-in-time restore requires blob versioning, change feed, and soft-delete to be enabled.

```bash
# Enable point-in-time restore
az storage account blob-service-properties update \
  --account-name {storageAccountName} \
  --resource-group {resourceGroup} \
  --enable-restore-policy true \
  --restore-days 7

# Restore blobs to a specific point in time
az storage blob restore \
  --account-name {storageAccountName} \
  --resource-group {resourceGroup} \
  --time-to-restore "2026-08-23T10:00:00Z"
```

### 4.3 Recover Soft-Deleted Blobs

```bash
# List soft-deleted blobs
az storage blob list \
  --account-name {storageAccountName} \
  --container-name {containerName} \
  --include d \
  --auth-mode login \
  --query "[?deleted==true].{name:name, deletedTime:properties.deletedTime}" -o table

# Undelete a specific blob
az storage blob undelete \
  --account-name {storageAccountName} \
  --container-name {containerName} \
  --name {blobName} \
  --auth-mode login
```

---

## 5. Disaster Recovery

### 5.1 RTO and RPO Targets

| Component | RPO (Recovery Point Objective) | RTO (Recovery Time Objective) | Justification |
|---|---|---|---|
| **Azure SQL Database** | 5 minutes (log backup interval) | 30 minutes (point-in-time restore) | Automatic backups with 5-minute log granularity |
| **Azure Key Vault** | 0 (soft-delete recovers exact state) | 5 minutes (secret recovery) | Soft-delete with purge protection |
| **Azure Service Bus** | 0 (messages in-flight are durable) | 15 minutes (geo-DR failover) | Premium tier with geo-DR (if configured) |
| **Azure Blob Storage** | 0 (GRS replication) | 1 hour (failover to secondary region) | Geo-redundant storage with failover |
| **Container Apps** | N/A (stateless) | 10 minutes (redeploy from ACR) | Container images in ACR with geo-replication |
| **Application Insights** | N/A (telemetry, not critical path) | N/A | Loss of telemetry does not affect operations |

### 5.2 Cross-Region Failover Considerations

#### Azure SQL Database

```bash
# Create a failover group (requires a secondary server in another region)
az sql failover-group create \
  --name {failoverGroupName} \
  --server {sqlServerName} \
  --partner-server {secondarySqlServerName} \
  --partner-resource-group {secondaryResourceGroup} \
  --resource-group {resourceGroup} \
  --add-db {databaseName} \
  --failover-policy Automatic \
  --grace-period 1
```

#### Service Bus (Premium Tier)

```bash
# Create a geo-disaster recovery pairing
az servicebus georecovery-alias set \
  --namespace-name {serviceBusNamespace} \
  --resource-group {resourceGroup} \
  --alias {aliasName} \
  --partner-namespace "/subscriptions/{subscriptionId}/resourceGroups/{secondaryResourceGroup}/providers/Microsoft.ServiceBus/namespaces/{secondaryServiceBusNamespace}"
```

#### Container Apps

Container Apps are stateless. Cross-region failover requires:

1. ACR with geo-replication enabled.
2. A secondary Container Apps environment in the failover region.
3. Azure Front Door or Traffic Manager for DNS-based failover.

```bash
# Enable ACR geo-replication
az acr replication create \
  --registry {acrName} \
  --location {secondaryRegion}
```

### 5.3 Disaster Recovery Test Procedure

Perform DR tests quarterly:

1. **SQL Failover Test:**
   - Trigger a manual failover to the secondary region.
   - Verify the gateway connects to the secondary database.
   - Verify all data is present.
   - Fail back to the primary region.

```bash
# Manual failover
az sql failover-group set-primary \
  --name {failoverGroupName} \
  --server {secondarySqlServerName} \
  --resource-group {secondaryResourceGroup}

# Fail back
az sql failover-group set-primary \
  --name {failoverGroupName} \
  --server {sqlServerName} \
  --resource-group {resourceGroup}
```

2. **Key Vault Recovery Test:**
   - Delete a non-production test secret.
   - Recover it using the soft-delete recovery procedure.
   - Verify the recovered secret matches the original.

3. **Service Bus DLQ Replay Test:**
   - Intentionally dead-letter a test message.
   - Replay it using the DLQ resubmission procedure.
   - Verify the message is processed successfully.

---

## Verification Checklist

- [ ] Azure SQL short-term retention configured (7/14/35 days per environment)
- [ ] Azure SQL long-term retention configured (production)
- [ ] Azure SQL backup redundancy matches environment requirements
- [ ] Key Vault soft-delete enabled with appropriate retention period
- [ ] Key Vault purge protection enabled (staging/production)
- [ ] Blob Storage soft-delete enabled with appropriate retention
- [ ] Blob Storage versioning enabled (staging/production)
- [ ] Blob Storage point-in-time restore enabled (production)
- [ ] Service Bus DLQ monitoring alerts configured
- [ ] DR test completed within the last quarter
- [ ] Post-restore managed identity access verified
- [ ] Post-restore EF Core migration state verified
