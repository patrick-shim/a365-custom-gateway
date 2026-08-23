# Incident Response Runbook

This runbook defines the incident response procedures for the A365 Custom Gateway. It covers severity classifications, response workflows, procedures for each incident type, escalation paths, communication templates, and post-incident review.

The gateway operates as two Azure Container Apps (API and Worker) with Azure SQL, Service Bus, Key Vault, and integrations with Microsoft Entra ID, Microsoft Graph, Microsoft Purview, and Agent 365. Incidents may originate from any of these components.

---

## Severity Classifications

Severity levels align with Azure Monitor alert severities (Sev 0 = Critical through Sev 3 = Informational).

| Severity | Name | Description | Response Time | Resolution Target | Examples |
|---|---|---|---|---|---|
| **Sev 0** | Critical | Complete service outage or security breach. All external agents affected. | 15 minutes | 1 hour | Azure SQL completely down, identity spoofing detected, credential exposure |
| **Sev 1** | High | Major degradation. Multiple agents affected or critical function unavailable. | 30 minutes | 4 hours | Service Bus unavailable, provisioning pipeline broken, Purview Enforce failing closed for all agents |
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
- All API requests return 401.
- Admin UI sign-in fails.
- Application Insights shows JWT validation exceptions.
- `/health/ready` returns unhealthy (identity provider check fails).

**Impact:** Sev 0 -- complete service outage for all users and agents.

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
3. Communicate to external agent operators that the gateway is unavailable due to an Entra ID outage.

**Recovery:** Auto-recovers when Entra ID is available. No manual steps required.

#### 1b. Agent Identity Mismatch (Failure-Mode #16)

**Symptoms:**
- Single external agent receives 403 `AGENT_IDENTITY_MISMATCH`.
- Security audit event logged with the mismatched `appid`/`azp` and `externalAgentId`.

**Impact:** Sev 2 -- single agent affected. **Security concern** -- potential identity spoofing attempt.

**Diagnosis:**

```kusto
// KQL: Find identity mismatch events
AuditEvents
| where eventType == "IdentityMismatch"
| project timestamp, externalAgentId, expectedClientId, actualClientId, callerIpAddress
| order by timestamp desc
| take 50
```

**Mitigation:**
1. Determine if this is a legitimate misconfiguration or an attack.
2. If misconfiguration: verify the correct `externalClientId` is stored on the `AgentRegistration` entity and that the external agent is using the correct app registration.
3. If attack: disable the agent immediately and escalate to Security (Sev 0).

```bash
# Disable the agent
curl -X POST "https://{gatewayDomain}/api/v1/agents/{agentId}:disable" \
  -H "Authorization: Bearer {adminToken}"
```

**Recovery:** Fix the identity binding or rotate the compromised credentials.

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
# Check the provisioning job status via gateway API
curl -s "https://{gatewayDomain}/api/v1/agents/{agentId}/operations" \
  -H "Authorization: Bearer {adminToken}" | jq '.items[0]'

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

For transient errors (5xx, timeout):
1. The worker automatically retries with exponential backoff and jitter.
2. If retries are exhausted, the message goes to the dead-letter queue.
3. Retry provisioning via the management API:

```bash
curl -X POST "https://{gatewayDomain}/api/v1/agents/{agentId}:retry-provisioning" \
  -H "Authorization: Bearer {adminToken}"
```

For permission errors (403):
1. Verify that the worker's managed identity has the required Graph permissions:
   - `Application.ReadWrite.OwnedBy`
   - `AgentIdentityBlueprint.ReadWrite.All`
   - `AgentIdentityBlueprintPrincipal.Create`
2. Re-grant permissions if missing (see Entra Setup Runbook).
3. Retry provisioning after permissions are fixed.

For beta API breaking changes (Failure-Mode #4):
1. Check if the Agent Registration API (beta) has changed.
2. If the beta API is broken, disable it via feature flag and fall back to CLI:

```bash
# Set the feature flag (environment variable on the Container App)
az containerapp update \
  --name {workerContainerAppName} \
  --resource-group {resourceGroup} \
  --set-env-vars "FeatureFlags__UseGraphAgentRegistration=false"
```

**Recovery:** Provisioning resumes from the last successful step (each step is idempotent).

#### 2b. Admin Approval Stuck (Failure-Mode #21)

**Symptoms:**
- Agent in `AwaitingAdminApproval` status for longer than the configured timeout (default 7 days).
- Reconciliation job logs stale status alerts.

**Impact:** Sev 3 -- single agent, no data-plane impact.

**Diagnosis:**

```kusto
// KQL: Find agents stuck in AwaitingAdminApproval
customEvents
| where name == "ReconciliationStaleStatus"
| where customDimensions["agentStatus"] == "AwaitingAdminApproval"
| project timestamp, tostring(customDimensions["agentId"]), tostring(customDimensions["daysInStatus"])
```

**Mitigation:**
1. Contact the M365 tenant administrator to approve the agent instance in the Microsoft 365 Admin Center.
2. If the instance was rejected, the reconciliation job will detect this and move the agent to `Failed`.

**Recovery:** Once approved, the reconciliation job detects the activation and moves the agent to `Active`.

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

**Recovery:** Auto-recovers when SQL is available. Outbox messages ensure no data loss -- pending operations will be processed from the outbox.

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
1. The outbox relay will automatically retry when Service Bus recovers. No manual intervention needed for message delivery.
2. If the namespace is in a degraded state, consider failing over to a secondary namespace (if geo-replication is configured).

**Recovery:** Auto-recovers. The outbox ensures no messages are lost. After recovery, there may be a burst of messages as the backlog is drained.

---

### 4. Content Policy Failures

#### 4a. Purview Unavailable in Enforce Mode (Failure-Mode #11)

**Symptoms:**
- AI interaction evaluations return 503 `PURVIEW_DEPENDENCY_UNAVAILABLE`.
- All agents in Enforce mode are unable to process AI interactions.
- Application Insights shows Purview API 5xx or timeout errors.

**Impact:** Sev 1 -- AI interaction evaluation is blocked for all Enforce-mode agents. AuditOnly agents are unaffected.

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

**Mitigation:**

Option 1: Wait for Purview recovery (fail-closed behavior is by design).

Option 2: Temporarily switch affected agents to AuditOnly mode:

```bash
# Switch to AuditOnly (requires Gateway.Administrator role)
curl -X PATCH "https://{gatewayDomain}/api/v1/agents/{agentId}/features" \
  -H "Authorization: Bearer {adminToken}" \
  -H "Content-Type: application/json" \
  -d '{"purviewMode": "AuditOnly"}'
```

> **Warning:** Switching from Enforce to AuditOnly means content is processed without DLP evaluation. This decision must be documented and approved by the Compliance team. An audit event is recorded for every mode change.

**Recovery:** When Purview recovers, switch agents back to Enforce mode. Review any content processed during the AuditOnly window.

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
  --name gateway-provisioning \
  --query "countDetails.deadLetterMessageCount" -o tsv

# Peek at DLQ messages
az servicebus queue peek-messages \
  --namespace-name {serviceBusNamespace} \
  --resource-group {resourceGroup} \
  --queue-name gateway-provisioning \
  --max-count 5 \
  --dead-letter
```

**Mitigation:**
1. Inspect the dead-lettered messages to determine the root cause.
2. Fix the underlying issue (permissions, schema, timeout).
3. Replay messages from the DLQ (see Backup-Recovery Runbook for DLQ replay procedures).

---

### 6. Security Incidents

#### 6a. Identity Spoofing Attempts

**Symptoms:**
- Multiple `AGENT_IDENTITY_MISMATCH` errors from the same IP address.
- Attempts to use one agent's token to access another agent's data.

**Impact:** Sev 0 -- active security incident.

**Immediate Actions:**

1. **Disable the affected agent(s):**

```bash
curl -X POST "https://{gatewayDomain}/api/v1/agents/{agentId}:disable" \
  -H "Authorization: Bearer {adminToken}"
```

2. **Block the source IP** (if applicable via NSG or WAF).
3. **Rotate the compromised agent's credentials** (see Credential Rotation Runbook).
4. **Collect evidence:**

```kusto
// KQL: Gather all activity from the suspicious client
union requests, dependencies, exceptions, traces
| where timestamp > ago(24h)
| where client_IP == "{suspiciousIpAddress}"
  or customDimensions["externalClientId"] == "{suspiciousClientId}"
| order by timestamp asc
```

5. **Escalate** to the Security team immediately.

#### 6b. Credential Exposure

**Symptoms:**
- Secret or certificate material found in logs, code repository, or external system.

**Impact:** Sev 0 -- active security incident.

**Immediate Actions:**

1. **Rotate the exposed credential immediately** (see Credential Rotation Runbook).
2. **Revoke all active sessions** for the affected app registration:

```bash
az ad sp credential delete \
  --id {affectedAppId} \
  --key-id {exposedKeyId}
```

3. **Audit access** -- check if the exposed credential was used:

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
