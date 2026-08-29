# Backup and Recovery Runbook

This runbook covers backup configuration, recovery procedures, and disaster recovery planning for all stateful components of the A365 Custom Gateway: Azure SQL Database, Azure Key Vault, Azure Service Bus, and Azure Blob Storage.

> **Current implementation boundary (2026-08-28):** the repository has no EF Core
> migration set. Current source isolates workflow v3 on
> `gateway-provisioning-v3`; retained workflow v2 stays on
> `gateway-provisioning-v2`, and historical v1 stays on `gateway-provisioning`.
> Development continuous mode has Active create-new and reuse-existing blueprint
> registrations. Both are Available in Microsoft 365 Admin Center; Gateway ingress
> returned HTTP 202, Agent 365 OTLP accepted sanitized exports, and blueprint-scoped
> Purview Enforce proved benign audit plus synthetic prompt blocking.
> Historical ambiguous operations remain non-replayable. Verify effective queue names
> before recovery and never attach one generation's receiver to another queue.
> The additive SQL prepare/finalize path is documented in
> [`upgrade-strategy.md`](upgrade-strategy.md). Azure CLI supports queue management
> but not the message-level peek/receive/send commands previously shown here. Use a
> reviewed Azure Service Bus SDK tool or Service Bus Explorer for message bodies, and
> only with explicit incident authorization. The two historical-v1 DLQ messages and
> the three reviewed failed-canary messages on `gateway-provisioning-v2` must not be
> inspected beyond approved metadata, replayed, settled, or purged as part of routine
> recovery testing. The canary controller's reviewed-evidence/count exception is
> verification only, not message-disposition authority.
> Resource/SKU/retention/geo-recovery sections below are procedures and target
> controls, not proof that each feature is deployed. Verify actual development state
> from [`development-deployment-status.md`](development-deployment-status.md) and use
> read-only discovery before any restore or failover.

> The verified development state is API revision
> `ca-gateway-api-dev--purviewguard-20260828222324`, worker revision
> `ca-gateway-worker-dev-vnet--rbacrefresh-202608282058`, v3 queue `0/0/10`,
> retained v2 `0/0/3`, and historical v1 `0/0/2`. The typed catalog is 12 total / 7
> compatible / 5 incompatible. The current canary is Active, and
> recovery work does not authorize opening admission or processing. Exact digests
> and chronology remain in
> [`development-deployment-status.md`](development-deployment-status.md).
>
> The current development database has the four prepare deltas applied and verified;
> scoped-idempotency finalization remains unapplied. The retained, distinct recovery
> baseline and immutable prepare provenance remain valid absent a real age, integrity,
> recovery, or schema reason to replace them. Evidence
> `live-state-20260828-v3-success-final.json` predates the two continuous canaries. It
> remains earlier recovery evidence, not current SQL job/outbox evidence. No
> historical operation may be replayed as part of recovery.
> Development SQL public network access is policy-enforced `Disabled`; do not weaken
> that policy or widen the canary controller's evidence-age limit to bypass this
> recovery gate.

---

## Prerequisites

| Requirement | Details |
|---|---|
| **Azure role** | Contributor on the resource group (for restore operations), Key Vault Administrator (for secret recovery), SQL Server Contributor (for database restore) |
| **Azure CLI** | v2.60+ |
| **SQL tooling** | `sqlcmd` or an equivalent private-DNS-aware SQL client for read-only schema verification |
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
  --name {databaseName} \
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

Run this from the approved private-DNS-aware runner. `az sql query` is not a
supported Azure CLI command used by this repository; use the same non-echoing Entra
`sqlcmd` path as the schema-upgrade procedure.

```powershell
sqlcmd `
  -S "tcp:{sqlServerName}.database.windows.net,1433" `
  -d "{databaseName}-restored-20260823" `
  -G `
  -Q "SET NOCOUNT ON; SELECT COUNT_BIG(*) AS AgentCount FROM dbo.AgentRegistrations WHERE IsDeleted = 0;"
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

2. **Check the implemented schema level:**

```bash
# Run from a private-DNS-aware host. This is a read-only schema check.
sqlcmd -S "tcp:{sqlServerName}.database.windows.net,1433" \
  -d "{databaseName}-restored-20260823" -G \
  -Q "SELECT COL_LENGTH('dbo.AgentRegistrations','BlueprintSelectionMode') AS BlueprintSelectionMode, COL_LENGTH('dbo.ProvisioningJobs','WorkflowVersion') AS WorkflowVersion, OBJECT_ID('dbo.AgentIngressCredentials','U') AS AgentIngressCredentials, COL_LENGTH('dbo.IdempotencyRecords','AgentRegistrationId') AS IdempotencyAgentRegistrationId, OBJECT_ID('dbo.IngressRateLimitBuckets','U') AS IngressRateLimitBuckets;"
```

Also inventory the indexes on `dbo.IdempotencyRecords`. A prepared database retains
both the old globally unique key-only index and the filtered scoped compound index;
a finalized database retains only the scoped index plus legacy NULL-scope rows. That
phase determines API rollback compatibility. Never route a legacy NULL-scope-writing
API revision to a finalized database without an explicitly reviewed compatibility
recovery.

The restored database contains only salted Gateway-key verifier material, never the
clear keys. A key issued after the restore point will not validate against the older
copy. Do not attempt to recover or reconstruct it from SQL: after controlled cutover,
issue a replacement through the administrator credential endpoint, deploy/verify it,
then revoke stale metadata when safe. One-time registration/rotation responses must
not be recovered from idempotency rows because they are deliberately never cached
there.

3. **Apply a reviewed additive upgrade only when required.** Follow
   [`upgrade-strategy.md`](upgrade-strategy.md). Rehearse the exact script and recovery
   plan on a disposable copy before applying it to a restored environment. Do not run
   `dotnet ef database update`; no EF migration set is present.

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

The current design has separate generation queues:

| Queue Name | Purpose | DLQ Threshold (Alert) |
|---|---|---|
| `gateway-provisioning-v3` | Current-source workflow-v3 provisioning; API is sole publisher and v3 worker sole receiver | 5 messages |
| `gateway-provisioning-v2` | Retained workflow-v2 queue; preserve its three failed-canary DLQ messages | 5 messages |
| `gateway-provisioning` | Historical workflow-v1 queue; preserve its two existing DLQ messages | 5 messages |

```bash
# Read queue runtime metadata; this does not inspect message bodies.
az servicebus queue show \
  --namespace-name {serviceBusNamespace} \
  --resource-group {resourceGroup} \
  --name gateway-provisioning-v3 \
  --query "countDetails.{active:activeMessageCount,scheduled:scheduledMessageCount,deadLetter:deadLetterMessageCount}" -o json
```

Run the same read-only query for all three generation-isolated queues. The v2 queue
currently has three reviewed failed-canary DLQ messages and the historical queue has
two older messages. The v3 queue is currently `0/0/10`; its DLQ entries are retained
evidence, while current successful registrations are Active. Keep
the queue isolated. Do not inspect payloads or settle any retained message as routine
verification.

### 3.2 DLQ Message Inspection

Azure CLI has no supported message-level command for this operation. Use the Azure
portal's Service Bus Explorer or a small, reviewed `Azure.Messaging.ServiceBus` tool
with **peek** semantics. Record who authorized the inspection, the queue/subqueue,
message identifiers, and correlation result without copying payloads into a runbook
or chat. For the current development incident, inspection is still blocked.

### 3.3 DLQ Message Resubmission

Replay is a destructive state change, not a routine restore step. After the root
cause is fixed, independently correlate the message to a current, replay-safe
operation; review the workflow version and side-effect boundary; obtain explicit
operator approval; then use a reviewed SDK tool or Service Bus Explorer to resubmit
with the intended identifiers. Never replay a legacy job into another workflow
generation, and do not use any of the five retained development DLQ messages for the
workflow-v3 canary.

### 3.4 DLQ Purge (Discard Messages)

Purge permanently destroys evidence and recovery options. There is no repository
script or Azure CLI message command approved for it. Require explicit message-by-
message disposition, incident-owner approval, and an audited SDK/portal operation.
Bulk purge is not authorized for the current development queue.

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

3. **Service Bus recovery test:**
   - Use an emulator or a separately isolated test namespace/queue, never the current
     development DLQ.
   - Exercise peek, explicit disposition approval, idempotent replay, and audit
     evidence with synthetic data.
   - Do not create/replay a live message without separate authorization.

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
- [ ] Post-restore implemented schema level and additive N:N workflow schema verified
