# Upgrade Strategy Runbook

This runbook covers the deployment and upgrade strategy for the A365 Custom Gateway. It includes container image versioning, blue-green deployments via Container Apps revision management, database migration procedures, rollback processes, canary releases, and version compatibility.

---

## Prerequisites

| Requirement | Details |
|---|---|
| **Azure role** | Contributor on the resource group |
| **Azure CLI** | v2.60+ |
| **Container registry** | `{acrName}.azurecr.io` |
| **Container Apps** | `{apiContainerAppName}` (API), `{workerContainerAppName}` (Worker) |
| **EF Core tools** | `dotnet-ef` tool installed |
| **GitHub Actions** | CI/CD pipeline configured (see Entra Setup Runbook, Step 5) |

### Login

```bash
az login --tenant {tenantId}
az account set --subscription {subscriptionId}
```

---

## 1. Container Image Versioning

### 1.1 Tagging Strategy

All container images are tagged with the git SHA short hash (7 characters) from the commit that produced them. This provides a unique, traceable, and immutable identifier for each build.

| Tag Format | Example | Use |
|---|---|---|
| `gateway-api:{gitShortSha}` | `gateway-api:a1b2c3d` | Primary deployment tag |
| `gateway-worker:{gitShortSha}` | `gateway-worker:a1b2c3d` | Primary deployment tag |
| `gateway-api:latest` | `gateway-api:latest` | Development convenience only (never used in staging/production) |

### 1.2 Image Build and Push (CI/CD)

The GitHub Actions workflow builds and pushes images on every merge to `main`:

```bash
# Build and tag the API image
docker build -t {acrName}.azurecr.io/gateway-api:${GIT_SHA_SHORT} \
  -f src/Gateway.Api/Dockerfile .

# Build and tag the Worker image
docker build -t {acrName}.azurecr.io/gateway-worker:${GIT_SHA_SHORT} \
  -f src/Gateway.Provisioning.Worker/Dockerfile .

# Push to ACR
az acr login --name {acrName}
docker push {acrName}.azurecr.io/gateway-api:${GIT_SHA_SHORT}
docker push {acrName}.azurecr.io/gateway-worker:${GIT_SHA_SHORT}
```

### 1.3 Verify Images in ACR

```bash
# List recent API images
az acr repository show-tags \
  --name {acrName} \
  --repository gateway-api \
  --orderby time_desc \
  --top 10 -o table

# List recent Worker images
az acr repository show-tags \
  --name {acrName} \
  --repository gateway-worker \
  --orderby time_desc \
  --top 10 -o table
```

---

## 2. Blue-Green Deployments via Container Apps Revisions

Azure Container Apps supports revision-based deployments. Each deployment creates a new revision, and traffic is shifted after health checks pass. This provides zero-downtime deployments with instant rollback capability.

### 2.1 Deployment Flow

```
Build Image --> Push to ACR --> Create New Revision --> Health Check --> Shift Traffic
```

### 2.2 Deploy a New Revision

```bash
GIT_SHA_SHORT="a1b2c3d"  # Replace with the actual git SHA

# Step 1: Create a new revision for the API Container App
az containerapp update \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --image {acrName}.azurecr.io/gateway-api:${GIT_SHA_SHORT} \
  --revision-suffix "v-${GIT_SHA_SHORT}"

# Step 2: Create a new revision for the Worker Container App
az containerapp update \
  --name {workerContainerAppName} \
  --resource-group {resourceGroup} \
  --image {acrName}.azurecr.io/gateway-worker:${GIT_SHA_SHORT} \
  --revision-suffix "v-${GIT_SHA_SHORT}"
```

### 2.3 Verify the New Revision

```bash
# Check that the new revision is running
az containerapp revision list \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --query "[].{name:name, active:properties.active, runningState:properties.runningState, trafficWeight:properties.trafficWeight, createdTime:properties.createdTime}" -o table
```

### 2.4 Health Check Verification

Before shifting traffic, verify that the new revision passes health checks:

```bash
# Get the new revision's FQDN (if using multi-revision mode with labels)
NEW_REVISION_FQDN=$(az containerapp revision show \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --revision {apiContainerAppName}--v-${GIT_SHA_SHORT} \
  --query "properties.fqdn" -o tsv)

# Test health endpoints
curl -s "https://${NEW_REVISION_FQDN}/health/checks" | jq .
curl -s "https://${NEW_REVISION_FQDN}/health/ready" | jq .
```

If Container Apps is configured in single-revision mode, the platform automatically checks the health probe before routing traffic. For multi-revision mode, use traffic splitting below.

### 2.5 Shift Traffic to the New Revision

```bash
# Shift 100% of traffic to the new revision
az containerapp ingress traffic set \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --revision-weight {apiContainerAppName}--v-${GIT_SHA_SHORT}=100
```

### 2.6 Deactivate the Old Revision

After verifying the new revision is stable (recommended: wait at least 30 minutes in production):

```bash
# List all active revisions
az containerapp revision list \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --query "[?properties.active==\`true\`].name" -o tsv

# Deactivate the old revision (keep it available for emergency rollback)
az containerapp revision deactivate \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --revision {oldRevisionName}
```

> **Note:** Deactivated revisions consume no resources but can be reactivated instantly for rollback.

---

## 3. Database Migration Strategy

### 3.1 Migration Rules

EF Core migrations are applied **before** the application deployment. All migrations must follow these rules:

| Rule | Description |
|---|---|
| **Backward-compatible only** | New columns must have defaults or be nullable. Existing columns are never renamed or removed in the same release. |
| **Additive operations** | New tables, new columns, new indexes. Never drop a column that the running code still references. |
| **Two-phase removal** | To remove a column: Phase 1 -- deploy code that no longer reads the column. Phase 2 (next release) -- migration removes the column. |
| **No data-destructive changes** | Migrations must never DELETE data. Use soft-delete. |
| **Idempotent checks** | Migrations should use `IF NOT EXISTS` guards where possible. |

### 3.2 Pre-Deployment Migration Procedure

```bash
# Step 1: List pending migrations
"C:\Program Files\dotnet\dotnet.exe" ef migrations list \
  --project src/Gateway.Infrastructure \
  --startup-project src/Gateway.Api \
  --connection "Server={sqlServerName}.database.windows.net;Database={databaseName};Authentication=Active Directory Default;" \
  --no-build

# Step 2: Generate the SQL script for review (always review before applying)
"C:\Program Files\dotnet\dotnet.exe" ef migrations script \
  --project src/Gateway.Infrastructure \
  --startup-project src/Gateway.Api \
  --idempotent \
  --output migrations-{GIT_SHA_SHORT}.sql

# Step 3: Review the generated SQL script
# Look for: DROP, DELETE, ALTER COLUMN (type changes), data-destructive operations

# Step 4: Apply the migration
"C:\Program Files\dotnet\dotnet.exe" ef database update \
  --project src/Gateway.Infrastructure \
  --startup-project src/Gateway.Api \
  --connection "Server={sqlServerName}.database.windows.net;Database={databaseName};Authentication=Active Directory Default;"
```

### 3.3 CI/CD Migration Flow

In the GitHub Actions pipeline, migrations run as a separate step before the Container App deployment:

```yaml
# .github/workflows/deploy.yml (relevant section)
jobs:
  migrate:
    runs-on: ubuntu-latest
    steps:
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Apply EF Core migrations
        run: |
          dotnet tool restore
          dotnet ef database update \
            --project src/Gateway.Infrastructure \
            --startup-project src/Gateway.Api \
            --connection "Server={sqlServerName}.database.windows.net;Database={databaseName};Authentication=Active Directory Managed Identity;"

  deploy:
    needs: migrate  # Deploy only after migrations succeed
    runs-on: ubuntu-latest
    steps:
      # ... deploy Container App revision
```

### 3.4 Migration Rollback Procedure

If a migration causes issues, reverse it by applying the previous migration:

```bash
# Roll back to a specific migration
"C:\Program Files\dotnet\dotnet.exe" ef database update {PreviousMigrationName} \
  --project src/Gateway.Infrastructure \
  --startup-project src/Gateway.Api \
  --connection "Server={sqlServerName}.database.windows.net;Database={databaseName};Authentication=Active Directory Default;"
```

> **Warning:** Rollback only works if the migration's `Down()` method is properly implemented. Always test migration rollbacks in a non-production environment.

For emergency situations where `Down()` is not available:

```bash
# Generate a rollback script
"C:\Program Files\dotnet\dotnet.exe" ef migrations script \
  --project src/Gateway.Infrastructure \
  --startup-project src/Gateway.Api \
  {CurrentMigrationName} {PreviousMigrationName} \
  --output rollback-{GIT_SHA_SHORT}.sql

# Review and apply the rollback script manually
# sqlcmd or Azure Portal Query Editor
```

---

## 4. Rollback Procedure

### 4.1 Container App Rollback

To roll back to the previous revision:

```bash
# Step 1: Identify the previous stable revision
az containerapp revision list \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --query "sort_by([?properties.active==\`true\` || properties.active==\`false\`], &properties.createdTime)[-2:].{name:name, createdTime:properties.createdTime, active:properties.active}" -o table

# Step 2: Activate the previous revision (if deactivated)
az containerapp revision activate \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --revision {previousRevisionName}

# Step 3: Shift traffic back to the previous revision
az containerapp ingress traffic set \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --revision-weight {previousRevisionName}=100

# Step 4: Repeat for the Worker Container App
az containerapp revision activate \
  --name {workerContainerAppName} \
  --resource-group {resourceGroup} \
  --revision {previousWorkerRevisionName}

az containerapp ingress traffic set \
  --name {workerContainerAppName} \
  --resource-group {resourceGroup} \
  --revision-weight {previousWorkerRevisionName}=100
```

### 4.2 When to Rollback vs. Fix Forward

| Scenario | Decision | Reasoning |
|---|---|---|
| Health checks failing on new revision | **Rollback** | Immediate impact; fix and redeploy |
| Elevated error rate (>5% increase) | **Rollback** | User-facing impact; root cause unknown |
| Performance regression (p95 latency >2x) | **Rollback** | User-facing impact |
| Single non-critical bug | **Fix forward** | Deploy a patch; minimal user impact |
| Minor UI issue | **Fix forward** | No functional impact |
| Database migration failure | **Rollback migration + rollback app** | Must keep app and schema in sync |
| Security vulnerability in new code | **Rollback immediately** | Security takes priority |

### 4.3 Full Rollback Checklist

For a complete rollback (app + database):

1. [ ] Shift API traffic to previous revision.
2. [ ] Shift Worker traffic to previous revision.
3. [ ] Roll back database migration (if migration was part of this release).
4. [ ] Verify `/health/checks` returns healthy.
5. [ ] Verify `/health/ready` returns ready.
6. [ ] Verify external agent token acquisition works.
7. [ ] Verify provisioning pipeline functions.
8. [ ] Monitor error rates for 30 minutes.
9. [ ] Communicate status to stakeholders.

---

## 5. Canary Releases (Production)

For production deployments, use canary releases to gradually shift traffic to the new revision while monitoring for issues.

### 5.1 Canary Release Stages

| Stage | Traffic to New Revision | Monitoring Window | Proceed If |
|---|---|---|---|
| 1 | 10% | 15 minutes | Error rate < baseline + 1%, p95 latency < baseline + 20% |
| 2 | 50% | 30 minutes | Error rate < baseline + 0.5%, p95 latency < baseline + 10% |
| 3 | 100% | 60 minutes | Metrics stable at baseline |

### 5.2 Canary Deployment Commands

```bash
# Stage 1: 10% canary
az containerapp ingress traffic set \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --revision-weight \
    {previousRevisionName}=90 \
    {apiContainerAppName}--v-${GIT_SHA_SHORT}=10

# Monitor for 15 minutes (check Application Insights)
# KQL query to compare error rates between revisions:
# requests
# | where timestamp > ago(15m)
# | summarize
#     errorRate = countif(success == false) * 100.0 / count(),
#     p95_latency = percentile(duration, 95)
#   by cloud_RoleInstance
# | order by cloud_RoleInstance

# Stage 2: 50% canary
az containerapp ingress traffic set \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --revision-weight \
    {previousRevisionName}=50 \
    {apiContainerAppName}--v-${GIT_SHA_SHORT}=50

# Monitor for 30 minutes

# Stage 3: 100% promotion
az containerapp ingress traffic set \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --revision-weight {apiContainerAppName}--v-${GIT_SHA_SHORT}=100
```

### 5.3 Canary Abort

If metrics deteriorate at any stage:

```bash
# Abort: shift all traffic back to the previous revision
az containerapp ingress traffic set \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --revision-weight {previousRevisionName}=100
```

### 5.4 Monitoring During Canary

Key metrics to watch during canary stages:

```kusto
// KQL: Compare error rates between revisions
requests
| where timestamp > ago(30m)
| extend revision = tostring(customDimensions["kubernetes.io/revision"])
| summarize
    totalRequests = count(),
    failedRequests = countif(success == false),
    errorRate = round(countif(success == false) * 100.0 / count(), 2),
    p50_ms = round(percentile(duration, 50), 1),
    p95_ms = round(percentile(duration, 95), 1),
    p99_ms = round(percentile(duration, 99), 1)
  by revision
| order by revision asc
```

---

## 6. Version Compatibility Matrix

The API, database schema, and Worker must be compatible. Use this matrix to track version compatibility across releases.

### 6.1 Compatibility Rules

| Rule | Description |
|---|---|
| **API N + DB N** | Required. API version must be compatible with the current database schema. |
| **API N + DB N-1** | Required. The API must work with the previous database schema (supports rollback). |
| **API N-1 + DB N** | Required. The previous API must work with the new database schema (supports canary with mixed revisions). |
| **Worker N + API N** | Required. Worker and API must run the same contract version. |
| **Worker N + API N-1** | Best effort. Worker should handle messages from the previous API version. |

### 6.2 Version Tracking

Maintain a compatibility matrix in the repository:

| Release | API Version | DB Schema Version | Worker Version | Compatible With |
|---|---|---|---|---|
| v1.0.0 | `a1b2c3d` | Migration `20260801_InitialCreate` | `a1b2c3d` | DB: Initial |
| v1.1.0 | `e4f5g6h` | Migration `20260815_AddPurviewDecisionIndex` | `e4f5g6h` | DB: v1.0.0, v1.1.0 |
| v1.2.0 | `i7j8k9l` | Migration `20260823_AddReconciliationColumns` | `i7j8k9l` | DB: v1.1.0, v1.2.0 |

### 6.3 Breaking Change Protocol

If a release contains a breaking schema change (rare, requires two-phase approach):

1. **Phase A release:** Deploy new code that supports both old and new schema. Migration adds new columns/tables but does not remove old ones.
2. **Monitoring period:** 1 week minimum in production.
3. **Phase B release:** Deploy migration that removes old columns/tables. Code no longer references old schema.

---

## 7. Maintenance Windows and Communication

### 7.1 Maintenance Window Policy

| Environment | Maintenance Window | Notification Lead Time |
|---|---|---|
| Development | Any time | None |
| Staging | Business hours (Mon-Fri, 9 AM - 5 PM local) | 1 hour |
| Production | Off-peak (Tue-Thu, 2 AM - 6 AM UTC) | 48 hours |
| Emergency (any environment) | Immediate | Best effort |

### 7.2 Pre-Deployment Communication

**Subject:** A365 Gateway -- Scheduled Maintenance

```
Maintenance Type: {Routine Update | Security Patch | Database Migration | Infrastructure Change}
Environment: {Production | Staging}
Scheduled Start: {UTC datetime}
Expected Duration: {minutes}
Expected Impact: {None (zero-downtime) | Brief health check failures (< 30 seconds) | Service unavailable for N minutes}

Changes Included:
- {Change 1 description}
- {Change 2 description}

Rollback Plan: {Automatic rollback if health checks fail | Manual rollback within N minutes}

Contact: {on-call engineer contact}
```

### 7.3 Post-Deployment Communication

```
Deployment Status: {Completed Successfully | Rolled Back | Completed with Issues}
Actual Duration: {minutes}
Changes Applied: {Yes/No per change item}

Issues Encountered: {None | Description}
Follow-up Required: {None | Description}
```

---

## Deployment Checklist

### Pre-Deployment

- [ ] All tests pass in CI
- [ ] Container images built and pushed to ACR
- [ ] EF Core migration script reviewed (no DROP, DELETE, or type changes)
- [ ] Version compatibility verified (API N works with DB N-1)
- [ ] Maintenance window communicated (production only)
- [ ] Rollback plan documented
- [ ] On-call engineer available

### Deployment

- [ ] Database migration applied successfully
- [ ] New Container App revisions created
- [ ] Health checks passing on new revisions
- [ ] Traffic shifted (canary stages for production)
- [ ] Metrics monitored during canary windows
- [ ] Full traffic cutover completed

### Post-Deployment

- [ ] `/health/checks` returns healthy
- [ ] `/health/ready` returns ready
- [ ] Error rate within baseline
- [ ] P95 latency within baseline
- [ ] External agent token acquisition verified
- [ ] Provisioning pipeline functional
- [ ] Old revisions deactivated (after stability period)
- [ ] Post-deployment communication sent
