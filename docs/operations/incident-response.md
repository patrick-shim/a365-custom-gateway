# Incident Response Runbook

This runbook defines the incident response procedures for the A365 Custom Gateway. It covers severity classifications, response workflows, procedures for each incident type, escalation paths, communication templates, and post-incident review.

The target steady state uses three Azure Container Apps (API, Admin UI, and one
Worker) with Azure SQL, Service Bus, Key Vault, and integrations with Microsoft
Entra ID, Microsoft Graph, Microsoft Purview, and Agent 365. Development currently
has a temporary four-app topology: the historical worker and the workflow-v3 VNet
worker both exist. See `development-deployment-status.md` before acting on a worker.
Incidents may originate from any of these components.

Current checkpoint (2026-08-28): workflow-v3 development continuous mode has Active
create-new and reuse-existing blueprint registrations. Both are Available in
Microsoft 365 Admin Center; bound ingress returned HTTP 202 and Agent 365 OTLP
accepted sanitized exports. Blueprint-scoped Purview Enforce produced benign audit
and synthetic prompt-block proof. The current API revision is
`ca-gateway-api-dev--purviewguard-20260828222324`; the worker is
`ca-gateway-worker-dev-vnet--rbacrefresh-202608282058`. Queue baselines are v3
`0/0/9`, v2 `0/0/3`, and v1 `0/0/2`. Preserve every retained message and historical
Microsoft artifact. The older SQL evidence predates the continuous canaries, and SQL
finalization remains unapplied.

Current source implements scoped first-use serialization with a SQL application lock
and fixed-minute SQL limiter buckets for credential, registration, and global scopes.
Provisioning separately holds a session-owned exclusive `sp_getapplock` per job for
the full stage attempt. These protections and their prepare schema are deployed and
verified in development, but none is real-SQL multi-replica/failover proved. If a concurrent duplicate,
missing 429, unexpected 503, or incorrect bucket boundary appears during an
authorized canary, close admission, preserve correlation/safe scope evidence, and
do not replay requests while triaging. Never infer exactly-once or production rate-
limit behavior from one-replica evidence or process-local test fallbacks.

---

## Severity Classifications

Severity levels align with Azure Monitor alert severities (Sev 0 = Critical through Sev 3 = Informational).

| Severity | Name | Description | Response Time | Resolution Target | Examples |
|---|---|---|---|---|---|
| **Sev 0** | Critical | Complete service outage or security breach. All external agents affected. | 15 minutes | 1 hour | Azure SQL completely down, identity spoofing detected, credential exposure |
| **Sev 1** | High | Major degradation. Multiple agents affected or critical function unavailable. | 30 minutes | 4 hours | Service Bus unavailable, provisioning pipeline broken, Purview dependency failing closed for all enabled agents |
| **Sev 2** | Moderate | Partial degradation. Single agent or non-critical function affected. | 2 hours | 24 hours | Single agent provisioning stuck, intermittent Graph API errors, elevated error rate |
| **Sev 3** | Low | Minor issue. No immediate user impact. | 8 hours (business hours) | 5 business days | Reconciliation drift detected, audit submission delays, DLQ messages accumulating |

---

## Incident Response Workflow

```
Detect --> Assess --> Mitigate --> Resolve --> Post-Mortem
```

### Phase 1: Detect

Incidents are detected through:

| Detection Source | Mechanism | Alert Channel |
|---|---|---|
| Azure Monitor alerts | Metric and log-based alerts on Container Apps, SQL, Service Bus | PagerDuty / Teams webhook |
| Application Insights | Custom metric alerts, availability tests, failure anomalies | Email + Teams |
| Health endpoints | `/health/checks` (liveness), `/health/ready` (readiness) probe failures | Container Apps platform restart + alert |
| Dead-letter queue depth | Service Bus DLQ message count exceeds threshold | Azure Monitor metric alert |
| Security audit events | `AuditEvent` records with security-relevant event types | SIEM integration / Log Analytics alert |
| External agent reports | Support tickets from external agent operators | Service desk |

### Phase 2: Assess

1. **Identify the affected component(s)** using the failure-mode table (see procedures below).
2. **Determine severity** using the classification matrix above.
3. **Identify the blast radius** -- how many agents and external clients are affected.
4. **Check for cascading failures** -- Service Bus backlog, outbox table growth, connection pool exhaustion.
5. **Record the incident** -- create an incident ticket with timestamp, detection source, initial assessment.

### Phase 3: Mitigate

Apply the appropriate mitigation from the response procedures below. Priority order:

1. Restore service availability (even with reduced functionality).
2. Prevent data loss or security exposure.
3. Communicate status to affected parties.

### Phase 4: Resolve

1. Apply the root-cause fix.
2. Verify resolution through health endpoints and test requests.
3. Confirm metrics return to baseline.
4. Close the incident ticket.

### Phase 5: Post-Mortem

Conduct a post-incident review within 5 business days for Sev 0 and Sev 1 incidents. See the post-incident review template at the end of this document.

---

## Response Procedures by Incident Type

### 1. Authentication and Authorization Failures

#### 1a. Entra ID Outage (Failure-Mode #1)

**Symptoms:**
- Admin UI sign-in fails.
- Application Insights shows JWT validation exceptions.
- `/health/ready` returns unhealthy (identity provider check fails).
- Gateway-key-authenticated ingress may still authenticate locally, but outbound
  Agent 365 token acquisition/export can fail while Entra is unavailable.

**Impact:** Control plane is unavailable and Agent 365 egress is impaired. Do not
describe this as an ingress-authentication outage without checking key-authenticated
data-plane evidence.

**Diagnosis:**

```bash
# Check Azure status for Entra ID
curl -s "https://status.azure.com/en-us/status" | grep -i "entra\|identity"

# Check Application Insights for auth failures
az monitor app-insights query \
  --app {appInsightsName} \
  --resource-group {resourceGroup} \
  --analytics-query "
    exceptions
    | where timestamp > ago(30m)
    | where type contains 'SecurityToken' or type contains 'OpenIdConnect'
    | summarize count() by type, bin(timestamp, 5m)
  "
```

**Mitigation:**
1. The gateway caches OIDC metadata with a bounded TTL. If the cache is still valid, existing sessions continue to work. No action needed.
2. If the cache has expired and Entra is still down:
   - The gateway will fail closed (by design). No workaround -- this is a Microsoft-side outage.
   - Monitor the Azure status page for recovery.
3. Communicate the observed control-plane/egress impact. Do not tell external agents
   to replace their Gateway keys or obtain Entra credentials.

**Recovery:** Auto-recovers when Entra ID is available. No manual steps required.

#### 1b. Agent Identity Mismatch (Failure-Mode #16)

**Symptoms:**
- Single external agent receives 403 `AGENT_IDENTITY_MISMATCH`.
- Security audit event identifies the key-selected registration and mismatched
  `externalAgentId` without logging the key.

**Impact:** Sev 2 -- single agent affected. **Security concern** -- potential identity spoofing attempt.

**Diagnosis:**

```kusto
// KQL: Find identity mismatch events
AuditEvents
| where eventType == "IdentityMismatch"
| project timestamp, externalAgentId, agentRegistrationId, credentialId, callerIpAddress
| order by timestamp desc
| take 50
```

**Mitigation:**
1. Determine if this is a legitimate misconfiguration or an attack.
2. If misconfiguration: verify the presented Gateway credential belongs to the
   intended `AgentRegistration` and that the body uses that row's exact
   `externalAgentId`. Do not substitute a blueprint/child ID or introduce a global
   bypass key.
3. If attack: disable the agent immediately and escalate to Security (Sev 0).

```bash
# Disable the agent
curl -X POST "https://{gatewayDomain}/api/v1/agents/{agentId}:disable" \
  -H "Authorization: Bearer {adminToken}" \
  -H "Idempotency-Key: {fresh-guid}"
```

**Recovery:** Correct the external client's registration/key mapping. If the clear
key is unavailable or compromised, issue and deploy a replacement, verify it, then
revoke the named old key. The API refuses to revoke the last usable credential.
Never expose a key, salt, or hash in incident notes.

---

### 2. Provisioning Failures

#### 2a. Graph API Errors During Provisioning (Failure-Modes #2, #3, #4)

**Symptoms:**
- Agent stuck in `Provisioning` or `Failed` status.
- Provisioning job shows failed step with Graph API error.
- Application Insights shows Graph API 5xx or 403 errors.

**Impact:** Sev 2 -- single agent cannot complete provisioning.

**Diagnosis:**

```bash
# List the known provisioning history for an agent
curl -s "https://{gatewayDomain}/api/v1/agents/{agentId}/provisioning-history" \
  -H "Authorization: Bearer {adminToken}" | jq '.items[0]'

# After obtaining a known operation ID, get its current status
curl -s "https://{gatewayDomain}/api/v1/operations/{operationId}" \
  -H "Authorization: Bearer {adminToken}"

# Check Application Insights for Graph API errors
az monitor app-insights query \
  --app {appInsightsName} \
  --resource-group {resourceGroup} \
  --analytics-query "
    dependencies
    | where timestamp > ago(1h)
    | where target contains 'graph.microsoft.com'
    | where success == false
    | summarize count() by resultCode, name, bin(timestamp, 5m)
  "
```

**Mitigation:**

For transient read errors (including throttling, 5xx, and timeout):
1. The worker abandons the delivery for bounded Service Bus redelivery.
2. If deliveries are exhausted, the message goes to the dead-letter queue.
3. Read the agent detail and retry only when the server-computed
   `retryProvisioning.supported` decision is `true`, after the deployment execution
   gate and root cause have been verified. Failed status alone is not enough;
   legacy, manual-intervention, active, ambiguous Registry, and in-flight Registry
   create states are non-replayable.

```bash
curl "https://{gatewayDomain}/api/v1/agents/{agentId}" \
  -H "Authorization: Bearer {adminToken}"

# Run only when the response contains retryProvisioning.supported=true.
curl -X POST "https://{gatewayDomain}/api/v1/agents/{agentId}:retry-provisioning" \
  -H "Authorization: Bearer {adminToken}" \
  -H "Idempotency-Key: {fresh-guid}"
```

For permission errors (403):
1. For worker-owned stages, verify that the v3 worker managed identity has the exact
   eight-role Microsoft Graph application allowlist:
   - `Application.Read.All`
   - `AppRoleAssignment.ReadWrite.All`
   - `AgentIdentityBlueprint.Create`
   - `AgentIdentityBlueprint.AddRemoveCreds.All`
   - `AgentIdentityBlueprint.Read.All`
   - `AgentIdentityBlueprintPrincipal.Create`
   - `AgentIdentity.Create.All`
   - `AgentIdentity.Read.All`
2. For the API Registry action, instead verify the signed-in user token has
   `Gateway.Administrator`, valid `oid`, and `access_as_user`; the Gateway API app has
   admin-consented delegated `AgentRegistration.ReadWrite.All` and
   `AgentRegistration.Read.All`; and the API managed-identity FIC matches its tenant-
   v2 issuer, API MI principal subject, and sole token-exchange audience.
3. Ask a tenant administrator to grant and consent to any missing permission (see Entra
   Setup Runbook). The deployment itself does not grant tenant permissions.
4. After permissions are fixed, read the agent again and retry only if the current
   server decision still reports `retryProvisioning.supported=true`.

Do not automatically retry a timed-out, throttled, disconnected, or 5xx Microsoft
Graph **mutation**. Its outcome is ambiguous; preserve the job for manual
intervention so a second create cannot silently duplicate resources. Workflow-v3
Registry completion persists a planned ID before POST and accepts the safe
returned/fallback ID immediately on HTTP 201. If the one POST outcome is unknown,
permit only exact planned-ID GET; close both windows and preserve manual state when
that read cannot reconcile the result. There is no documented `sourceAgentId` search
and no second POST is safe. The retained v2 canary predates planned-ID recovery and
remains a separate read-only reconciliation item.

For beta API breaking changes (Failure-Mode #4):
1. Check if the Agent Registration API (beta) has changed.
2. If the beta API is broken, close the delegated Registry action window and fail
   closed. Do not fall back to app-only or the Agent 365 CLI after an uncertain
   create; doing so can duplicate a registry record.

```bash
# Disable new registration/retry at the API before disabling worker execution.
az containerapp update \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --set-env-vars \
    "Provisioning__ExecutionEnabled=false" \
    "Agent365__DelegatedRegistry__Enabled=false"

# Disable worker-side provisioning. Workflow v3 performs no Registry HTTP here.
az containerapp update \
  --name {workerContainerAppName} \
  --resource-group {resourceGroup} \
  --set-env-vars \
    "ProvisioningWorker__ProcessingEnabled=false" \
    "ProvisioningWorker__ProvisioningExecutionEnabled=false"
```

For the fixed development controller, prefer
`operations/invoke-development-canary.ps1 -Action Deactivate` because it closes
registration and delegated-completion windows before verifying the worker inert.
`OpenAdmission` has both an API-enforced
crash deadline and a controller `finally` close: its operator window is 30--300
seconds after readiness, its rollout allowance is 60--300 seconds, and total
exposure is hard-capped at 600 seconds. If deactivation cannot be verified, stop and
inspect both fixed Container Apps read-only; do not retry, replay, or delete a
Microsoft resource as compensation.

**Recovery:** Keep an unknown outcome in manual intervention. A pre-POST OBO/config
failure may be retried only while the server still exposes the same exact-bound
required action. A durable returned ID may be reconciled by the same creator with GET
only. Resume worker provisioning only through the server-computed safe path.

#### 2b. Optional Instance Approval Stuck (Future flow; not implemented)

**Symptoms (only after that separate lifecycle is implemented):**
- An optional Teams/AI-teammate instance request is in the distinct future
  `AwaitingInstanceApproval` status beyond its reviewed timeout.
- The external provider or an administrator reports that the optional request is
  stale. The current Gateway does not implement a verified reconciliation adapter.

The current Gateway has no optional instance-request model, request ID, status, or
verified reconciliation adapter, so this section is not a current operational query.
The standard Agent ID blueprint, principal, Agent Identity, and registry flow is
programmatic and must not enter this future state. A real permission-consent/admin
handoff uses the implemented `AwaitingAdminApproval` status instead.

**Impact:** Sev 3 -- single agent, no data-plane impact.

**Diagnosis:**

```kusto
// Future-only KQL shape after AwaitingInstanceApproval is implemented
customEvents
| where name == "ReconciliationStaleStatus"
| where customDimensions["agentStatus"] == "AwaitingInstanceApproval"
| project timestamp, tostring(customDimensions["agentId"]), tostring(customDimensions["daysInStatus"])
```

**Mitigation:**
1. Confirm that this is the separately configured Teams/AI-teammate instance flow.
2. Contact the M365 tenant administrator to approve that optional instance in the Microsoft 365 Admin Center.
3. Record approval or rejection through the administrator-mediated workflow. Do not
   claim that the current Gateway automatically reconciles or changes agent state.

**Recovery:** Independently verify the external instance. A future reconciliation
adapter may automate the transition only after its documented external read and
state mapping are implemented and tested; current handling remains manual.

#### 2c. Worker Cannot Reach Private Azure SQL

**Symptoms:**
- A registration is accepted, but its operation remains `Pending` at `0%` with no
  current step.
- The API database health check succeeds while worker logs show SQL connection errors.
- Container Apps reports the worker as `Running`, but Service Bus deliveries are
  retried or dead-lettered.
- SQL error `47073` reports that public network access is disabled.

**Impact:** Sev 1 when all asynchronous provisioning is stalled while the synchronous
API and Admin UI remain available.

**Diagnosis:**

```bash
# Compare the API and worker Container Apps environments. These should resolve to the
# intended network topology for their shared private dependencies.
az containerapp show \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --query "properties.environmentId" -o tsv

az containerapp show \
  --name {workerContainerAppName} \
  --resource-group {resourceGroup} \
  --query "properties.environmentId" -o tsv

# Confirm the SQL network posture.
az sql server show \
  --name {sqlServerName} \
  --resource-group {resourceGroup} \
  --query "{state:state, publicNetworkAccess:publicNetworkAccess, privateEndpoints:length(privateEndpointConnections)}" -o table

# Inspect worker logs without printing configuration or secrets.
az containerapp logs show \
  --name {workerContainerAppName} \
  --resource-group {resourceGroup} \
  --type console \
  --tail 100

# Check active and dead-lettered provisioning counts.
az servicebus queue show \
  --namespace-name {serviceBusNamespace} \
  --resource-group {resourceGroup} \
  --name gateway-provisioning-v3 \
  --query "{active:countDetails.activeMessageCount, deadLetter:countDetails.deadLetterMessageCount, maxDeliveryCount:maxDeliveryCount}" -o table
```

Query `gateway-provisioning-v2` and `gateway-provisioning` separately for retained
metadata. Never use either DLQ as workflow-v3 recovery input.

Container Apps `Running`, a ready replica, and zero restarts prove only platform
health. They do not prove that the worker can reach SQL or process a message.

**Mitigation:**
1. Preserve the main queue and DLQ while diagnosing; do not replay or purge messages.
2. For the current development topology, verify the existing
   `ca-gateway-worker-dev-vnet` revision in the approved VNet with minimum replicas
   `0`, maximum `1`, no scaler, and processing, outbox relay, provisioning execution,
   and Registry provider/preview gates disabled. A new bootstrap or in-place
   environment migration is not an incident-default action.
3. Verify database connectivity from the deployed worker revision before allowing
   message processing.
4. Confirm that the real fail-closed development adapter is deployed and contains no
   stub-success behavior before registering a fresh canary. Production support is a
   separate gate because the Registry provider is beta.
5. Preserve the current DLQ messages: two historical-v1 messages and all three
   reviewed failed-canary v2 messages. They can be verified from approved evidence
   artifacts and exact counts without receiving or peeking their payloads.
   Any other payload inspection needs fresh explicit authorization and a reviewed peek-only
   tool; never infer correlation from timing alone.
6. Obtain fresh cutover authority before disabling or replacing the historical
   worker.

**Recovery:** After network and code readiness are verified, review idempotency and
run the single authorized workflow-v3 development registration through its isolated
queue. Do not replay a workflow-v1/v2 job through workflow v3, and do not
assign any uncorrelated DLQ message to that operation without payload evidence.
The deployed VNet worker carries the reviewed workflow-v3 runtime and is inert.
Reverify the API, Admin UI, and worker revisions plus all gates before the fresh
compatible registration. Record each queue's retained state separately in the
development status or incident record.

---

### 3. Data-Plane Failures

#### 3a. Azure SQL Down (Failure-Mode #5)

**Symptoms:**
- All API requests return 503.
- `/health/checks` returns unhealthy.
- Application Insights shows SQL connection timeouts.
- Service Bus messages accumulate because the worker cannot update state.

**Impact:** Sev 0 -- complete service outage.

**Diagnosis:**

```bash
# Check Azure SQL status
az sql db show \
  --server {sqlServerName} \
  --name {databaseName} \
  --resource-group {resourceGroup} \
  --query "{status:status, earliestRestoreDate:earliestRestoreDate}" -o table

# Check Application Insights for SQL errors
az monitor app-insights query \
  --app {appInsightsName} \
  --resource-group {resourceGroup} \
  --analytics-query "
    dependencies
    | where timestamp > ago(30m)
    | where type == 'SQL'
    | where success == false
    | summarize count() by resultCode, bin(timestamp, 5m)
  "
```

**Mitigation:**
1. If Azure SQL is experiencing a regional outage, wait for Azure recovery.
2. If the issue is database-specific (e.g., DTU exhaustion, connection limit):

```bash
# Scale up the database tier if DTU is exhausted
az sql db update \
  --server {sqlServerName} \
  --name {databaseName} \
  --resource-group {resourceGroup} \
  --service-objective S3

# Check current DTU utilization
az monitor metrics list \
  --resource "/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.Sql/servers/{sqlServerName}/databases/{databaseName}" \
  --metric "dtu_consumption_percent" \
  --interval PT5M \
  --start-time $(date -u -d '-1 hour' '+%Y-%m-%dT%H:%M:%SZ') -o table
```

**Recovery:** After SQL is available, keep processing gates controlled and verify due
pending rows, expired claims, terminal failures, and consumer idempotency before
allowing the backlog to drain. The outbox provides durable at-least-once delivery; it
does not guarantee no loss or exactly-once execution across every dependency failure.

#### 3b. Service Bus Unavailable (Failure-Mode #7)

**Symptoms:**
- Outbox messages accumulate in the database (status=Pending, growing count).
- Provisioning jobs do not progress.
- Observability export stops.
- Application Insights shows Service Bus send exceptions.

**Impact:** Sev 1 -- async operations stalled, but synchronous API responses (202 Accepted) still work because the outbox absorbs the write.

**Diagnosis:**

```bash
# Check Service Bus namespace status
az servicebus namespace show \
  --name {serviceBusNamespace} \
  --resource-group {resourceGroup} \
  --query "{status:status, provisioningState:provisioningState}" -o table

# Check queue metrics
az monitor metrics list \
  --resource "/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.ServiceBus/namespaces/{serviceBusNamespace}" \
  --metric "IncomingMessages" "OutgoingMessages" "DeadletteredMessages" \
  --interval PT5M \
  --start-time $(date -u -d '-1 hour' '+%Y-%m-%dT%H:%M:%SZ') -o table
```

**Mitigation:**
1. The outbox relay returns transient failures to `Pending` with bounded exponential
   backoff and recovers expired SQL Server claims. Inspect terminal `Failed` rows
   after `MaxRetryCount`; do not promise indefinite automatic recovery.
2. If the namespace is in a degraded state, consider failing over to a secondary namespace (if geo-replication is configured).

**Recovery:** Due pending rows resume after Service Bus recovers, and the backlog may
drain in a burst. Delivery remains at-least-once if Service Bus accepts a send before
the process can record `Published`. The Basic-tier queue has no broker duplicate
detection, so the consumer must remain idempotent and operations must be checked for
duplicate delivery before any manual replay.

For Agent 365 observability, distinguish exporter acceptance from downstream
landing. HTTP 200 with no rejected spans proves only OTLP request acceptance. Query
Microsoft Defender `CloudAppEvents` with the controlled correlation after allowing
for service delay and checking tenant licensing before declaring recovery. Current
Entra-child telemetry keeps `gen_ai.agent.id` and
`microsoft.a365.agent.blueprint.id` and intentionally omits `gen_ai.agent.type` and
`microsoft.a365.agent.platform.id`; do not add those attributes as an incident
workaround.

---

### 4. Content Policy Failures

#### 4a. Purview Unavailable (Failure-Mode #11)

**Symptoms:**
- AI interaction evaluations return 503 `PURVIEW_DEPENDENCY_UNAVAILABLE`.
- Purview-enabled agents in either `Enforce` or `AuditOnly` return dependency
  failures when their required Graph call is unavailable.
- Application Insights shows Purview Graph API 5xx, 429, or timeout errors.

**Impact:** Sev 1 -- AI interaction ingestion is blocked for affected Purview-
enabled agents. `AuditOnly` is not an availability bypass: it synchronously writes
metadata-only content activities and fails closed when Graph does not accept them.

**Diagnosis:**

```bash
# Check Purview API availability
az monitor app-insights query \
  --app {appInsightsName} \
  --resource-group {resourceGroup} \
  --analytics-query "
    dependencies
    | where timestamp > ago(30m)
    | where target contains 'graph.microsoft.com' and name contains 'processContent'
    | where success == false
    | summarize count() by resultCode, bin(timestamp, 5m)
  "
```

**Mitigation:** Keep the adapter fail closed while checking the Gateway API managed
identity, the exact three Graph roles, user/child/blueprint identifiers, tenant
policy, throttling guidance, and Microsoft service health. Do not switch to
`AuditOnly` as an outage workaround; it has its own synchronous Graph dependency.
Disabling Purview would permit unevaluated content and is a separate compliance and
security decision that requires explicit authorized change control, not an incident
automation step.

**Recovery:** After the dependency and tenant policy recover, run the authorized
synthetic-content checks from `purview-setup-runbook.md` before restoring normal
traffic. Confirm neither logs nor SQL contain prompt/response content. Account for
the documented at-least-once external audit boundary when a content-activity request
may have succeeded before the local failure.

---

### 5. Infrastructure Failures

#### 5a. Container App Crashes (Scaling Issues)

**Symptoms:**
- `/health/checks` probe failures trigger Container Apps restarts.
- Repeated crash loops visible in Container Apps logs.
- Metrics show high restart count.

**Impact:** Sev 0 (if all replicas affected) or Sev 1 (if partial).

**Diagnosis:**

```bash
# Check Container App revision status
az containerapp revision list \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --query "[].{name:name, runningState:properties.runningState, healthState:properties.healthState, replicas:properties.replicas}" -o table

# Check Container App logs
az containerapp logs show \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --type system \
  --follow

# Check application logs
az containerapp logs show \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --type console \
  --tail 100
```

**Mitigation:**
1. If OOM (out of memory): increase memory limits on the Container App.

```bash
az containerapp update \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --cpu 1.0 --memory 2.0Gi
```

2. If the crash is caused by a code bug in the latest revision: roll back to the previous revision.

```bash
# List revisions
az containerapp revision list \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} -o table

# Activate previous revision and shift traffic
az containerapp revision activate \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --revision {previousRevisionName}

az containerapp ingress traffic set \
  --name {apiContainerAppName} \
  --resource-group {resourceGroup} \
  --revision-weight {previousRevisionName}=100
```

**Recovery:** Deploy a fix and shift traffic to the new revision.

#### 5b. Dead-Letter Queue Accumulation (Failure-Mode #8)

**Symptoms:**
- Azure Monitor alert fires on DLQ depth exceeding threshold.
- Provisioning jobs not progressing.
- Observability export records not being processed.

**Impact:** Sev 2 or Sev 3 depending on message type.

**Diagnosis:**

```bash
# Check DLQ depth
az servicebus queue show \
  --namespace-name {serviceBusNamespace} \
  --resource-group {resourceGroup} \
  --name gateway-provisioning-v3 \
  --query "countDetails.deadLetterMessageCount" -o tsv

# Azure CLI does not expose supported message-level DLQ peek commands. With explicit
# incident authorization, use portal Service Bus Explorer or a reviewed
# Azure.Messaging.ServiceBus peek-only tool. Never copy payloads into chat/runbooks.
```

If the alert concerns either retained queue, preserve its DLQ and follow only a
separately authorized generation-specific disposition procedure; never replay it
into `gateway-provisioning-v3`.

At the current development checkpoint, `gateway-provisioning-v2` has exactly three
reviewed retained messages and `gateway-provisioning` has exactly two historical
retained messages. The v3 queue must begin empty. Those known baselines are evidence,
not a backlog to drain. A
different count is a new incident and blocks activation, but it does not authorize
payload access or disposition.

**Mitigation:**
1. Use existing reviewed evidence first. Peek a dead-lettered message only with
   explicit authorization when its root cause cannot otherwise be established; do
   not receive or settle it as part of diagnosis.
2. Fix the underlying issue (permissions, schema, timeout).
3. Verify that the consumer's deployed code path is production capable and that replay
   cannot create duplicate or false-success side effects.
4. Correlate each message to a known record or operation and review its idempotency
   boundary.
5. Obtain explicit operator approval before replaying or discarding a message (see the
   Backup-Recovery Runbook for DLQ procedures).

> **Safety gate:** Never replay or purge a DLQ message while its network/code root
> cause remains unresolved. Purge is destructive; replay can repeat side effects.

---

### 6. Security Incidents

#### 6a. Identity Spoofing Attempts

**Symptoms:**
- Multiple `AGENT_IDENTITY_MISMATCH` errors from the same IP address.
- Attempts to use one registration's Gateway key with another `externalAgentId`.

**Impact:** Sev 0 -- active security incident.

**Immediate Actions:**

1. **Disable the affected agent(s):**

```bash
curl -X POST "https://{gatewayDomain}/api/v1/agents/{agentId}:disable" \
  -H "Authorization: Bearer {adminToken}" \
  -H "Idempotency-Key: {fresh-guid}"
```

2. **Block the source IP** (if applicable via NSG or WAF).
3. **Issue a replacement Gateway key through the Administrator route, deploy and
   verify it, then revoke the named compromised key.** Do not log the clear key and
   do not revoke the last usable key before the replacement is proven. A Gateway-
   worker FIC change is not an ingress-key containment action.
4. **Collect evidence:**

```kusto
// KQL: Gather all activity from the suspicious client
union requests, dependencies, exceptions, traces
| where timestamp > ago(24h)
| where client_IP == "{suspiciousIpAddress}"
  or customDimensions["agentRegistrationId"] == "{registrationId}"
| order by timestamp asc
```

5. **Escalate** to the Security team immediately.

#### 6b. Credential Exposure

**Symptoms:**
- Gateway API key, secret, certificate, assertion, or token material found in logs,
  code repository, or an unauthorized external system.

**Impact:** Sev 0 -- active security incident.

**Immediate Actions:**

1. **For a Gateway registration key:** issue/deploy/verify a replacement, then call
   the named credential revoke endpoint. Record only safe key ID/timestamps. If the
   issuance response is lost, issue another replacement; never recover it from SQL,
   audit, logs, or idempotency storage.
2. **For separately identified Entra app material only:** follow the approved Entra
   rotation procedure. Do not run this example against a Gateway key:

```bash
az ad sp credential delete \
  --id {affectedAppId} \
  --key-id {exposedKeyId}
```

3. **Audit access** using the appropriate source. Gateway-key events are correlated
   by safe credential/registration IDs; Entra material uses sign-in logs:

```kusto
// KQL: Check for unauthorized access with the exposed credential
SigninLogs
| where AppId == "{affectedAppId}"
| where TimeGenerated > ago(7d)
| project TimeGenerated, UserPrincipalName, IPAddress, Status, ConditionalAccessStatus
```

4. **Report** per organizational data breach notification policy.

---

## Escalation Matrix

| Severity | Primary Responder | Escalation (30 min no resolution) | Executive Notification |
|---|---|---|---|
| Sev 0 | On-call engineer | Engineering Lead + Security Lead | VP Engineering (immediate) |
| Sev 1 | On-call engineer | Engineering Lead | VP Engineering (1 hour) |
| Sev 2 | Assigned engineer (business hours) | Team Lead | None |
| Sev 3 | Assigned engineer (next sprint) | None | None |

### Contact List (Template)

| Role | Name | Contact |
|---|---|---|
| On-call engineer | {rotatingSchedule} | PagerDuty |
| Engineering Lead | {name} | {email} / {phone} |
| Security Lead | {name} | {email} / {phone} |
| M365 Tenant Admin | {name} | {email} |
| Microsoft Support | {contractId} | Azure Support Portal |

---

## Communication Templates

### External Agent Operator Notification

**Subject:** A365 Gateway -- Service Disruption Notification

```
Status: {Investigating | Mitigating | Resolved}
Impact: {Description of impact to external agents}
Start Time: {UTC timestamp}
Affected Agents: {All | Specific agent IDs}

Current Status:
{Brief description of the issue and current response actions}

Next Update: {Time of next update, e.g., "30 minutes" or specific time}

If you have questions, contact: {supportEmail}
```

### Internal Status Update

**Subject:** [SEV-{N}] A365 Gateway Incident -- {Brief Title}

```
Incident ID: {ticketId}
Severity: {Sev 0-3}
Status: {Investigating | Mitigating | Resolved}
Start Time: {UTC timestamp}
Detection: {How the incident was detected}
Impact: {Blast radius -- number of agents, user impact}
Root Cause: {Known | Under investigation}

Timeline:
- {HH:MM UTC} -- {Event description}
- {HH:MM UTC} -- {Event description}

Current Actions:
- {What is being done right now}

Next Steps:
- {What will happen next}
```

---

## Post-Incident Review Template

Complete within 5 business days for Sev 0 and Sev 1 incidents.

```markdown
# Post-Incident Review: {Incident Title}

**Date:** {date}
**Duration:** {start} to {end} ({total duration})
**Severity:** Sev {N}
**Participants:** {names}

## Summary
{2-3 sentence summary of what happened and the impact}

## Timeline
| Time (UTC) | Event |
|---|---|
| {HH:MM} | {First detection or trigger} |
| {HH:MM} | {Assessment / severity assigned} |
| {HH:MM} | {Mitigation actions taken} |
| {HH:MM} | {Resolution confirmed} |

## Root Cause
{Technical description of the root cause}

## Impact
- **Users/agents affected:** {count and scope}
- **Duration of impact:** {minutes/hours}
- **Data loss:** {Yes/No -- describe if yes}
- **SLA impact:** {Yes/No}

## What Went Well
- {Item 1}
- {Item 2}

## What Could Be Improved
- {Item 1}
- {Item 2}

## Action Items
| Action | Owner | Due Date | Status |
|---|---|---|---|
| {Description} | {Name} | {Date} | Open |
| {Description} | {Name} | {Date} | Open |

## Lessons Learned
{Key takeaways for the team}
```
