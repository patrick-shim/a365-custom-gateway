# Microsoft Purview Setup Runbook

This runbook covers the configuration of Microsoft Purview for the A365 Custom Gateway. It includes creating sensitivity labels, DLP compliance policies and rules via PowerShell, configuring the gateway's Purview evaluation mode, granting API permissions, and verifying policy evaluation.

DLP policy management is PowerShell-only. There is no Microsoft Graph API equivalent for creating or managing DLP compliance policies. The gateway calls the Purview `processContent` and `protectionScopes/compute` Graph APIs at runtime, but the policies those APIs evaluate must be created through the Security & Compliance PowerShell module.

---

## Prerequisites

| Requirement | Details |
|---|---|
| **Entra role** | Compliance Administrator or Global Administrator |
| **License** | Microsoft 365 E5 (or E5 Compliance add-on) for DLP and Information Protection |
| **PowerShell** | PowerShell 7.2+ |
| **Module** | `ExchangeOnlineManagement` v3.4+ (includes Security & Compliance cmdlets) |
| **Module** | `Microsoft.Graph` PowerShell SDK (for API permission grants) |
| **Gateway API client ID** | `{gatewayApiClientId}` (from the Entra setup runbook) |
| **Tenant ID** | `{tenantId}` |
| **Gateway managed identity** | Object ID of the Gateway API's system-assigned managed identity: `{gatewayManagedIdentityObjectId}` |
| **Worker managed identity** | Object ID of the Provisioning Worker's system-assigned managed identity: `{workerManagedIdentityObjectId}` |

### Install Required Modules

```powershell
# Install Exchange Online Management (includes Security & Compliance cmdlets)
Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser -Force

# Install Microsoft Graph PowerShell SDK
Install-Module -Name Microsoft.Graph -Scope CurrentUser -Force
```

### Connect to Security & Compliance

```powershell
# Connect to Security & Compliance PowerShell
Connect-IPPSSession -UserPrincipalName admin@{tenantDomain}
```

> This opens a browser-based authentication prompt. The signed-in user must have the Compliance Administrator role.

---

## Step 1: Create Information Protection Sensitivity Labels

Sensitivity labels classify content processed through the gateway. These labels are used by Purview DLP policies to determine enforcement actions.

### 1.1 Create Sensitivity Labels

```powershell
# Create a parent label for AI Agent content
New-Label `
  -DisplayName "AI Agent Content" `
  -Name "ai-agent-content" `
  -Comment "Classification for content processed through the A365 Gateway" `
  -Tooltip "Content processed by external AI agents via the A365 Gateway"

# Create sub-labels for different sensitivity levels
New-Label `
  -DisplayName "General" `
  -Name "ai-agent-general" `
  -ParentId (Get-Label -Identity "ai-agent-content").Guid `
  -Comment "Non-sensitive AI agent content"

New-Label `
  -DisplayName "Confidential" `
  -Name "ai-agent-confidential" `
  -ParentId (Get-Label -Identity "ai-agent-content").Guid `
  -Comment "Confidential AI agent content - restricted distribution"

New-Label `
  -DisplayName "Highly Confidential" `
  -Name "ai-agent-highly-confidential" `
  -ParentId (Get-Label -Identity "ai-agent-content").Guid `
  -Comment "Highly confidential AI agent content - blocked from external processing"
```

### 1.2 Publish Labels

Labels must be published via a label policy to be available for DLP evaluation:

```powershell
# Create a label policy that publishes the labels to all users
New-LabelPolicy `
  -Name "A365 Gateway AI Content Policy" `
  -Labels "ai-agent-general", "ai-agent-confidential", "ai-agent-highly-confidential" `
  -Comment "Publishes AI agent content sensitivity labels for A365 Gateway DLP evaluation" `
  -ExchangeLocation "All"
```

### Verification -- Step 1

```powershell
# List all labels
Get-Label | Format-Table DisplayName, Name, Guid, ParentId

# Verify label policy
Get-LabelPolicy -Identity "A365 Gateway AI Content Policy" | Format-List Name, Labels, ExchangeLocation
```

---

## Step 2: Create DLP Compliance Policy and Rules

DLP policies define what content should be blocked, audited, or allowed when processed through the gateway. The gateway calls `processContent` at runtime; Purview evaluates the content against these policies and returns policy actions.

### 2.1 Create the DLP Policy

```powershell
# Create a DLP policy for AI agent content
New-DlpCompliancePolicy `
  -Name "A365 Gateway Content Protection" `
  -Comment "Evaluates content processed through the A365 Gateway for sensitive information" `
  -ExchangeLocation "All" `
  -Mode "Enable"
```

> **Note:** Set `-Mode "TestWithNotifications"` for initial testing, then change to `"Enable"` for production enforcement.

### 2.2 Create DLP Rules

```powershell
# Rule 1: Block content containing highly sensitive information types
New-DlpComplianceRule `
  -Name "Block Highly Sensitive Content" `
  -Policy "A365 Gateway Content Protection" `
  -ContentContainsSensitiveInformation @(
    @{
      Name = "Credit Card Number"
      MinCount = 1
      MaxConfidence = 100
      MinConfidence = 85
    },
    @{
      Name = "U.S. Social Security Number (SSN)"
      MinCount = 1
      MaxConfidence = 100
      MinConfidence = 85
    },
    @{
      Name = "International Banking Account Number (IBAN)"
      MinCount = 1
      MaxConfidence = 100
      MinConfidence = 85
    }
  ) `
  -BlockAccess $true `
  -Comment "Blocks AI agent content containing high-confidence sensitive data"

# Rule 2: Audit content containing potentially sensitive information
New-DlpComplianceRule `
  -Name "Audit Potentially Sensitive Content" `
  -Policy "A365 Gateway Content Protection" `
  -ContentContainsSensitiveInformation @(
    @{
      Name = "Credit Card Number"
      MinCount = 1
      MaxConfidence = 84
      MinConfidence = 65
    },
    @{
      Name = "All Full Names"
      MinCount = 3
      MaxConfidence = 100
      MinConfidence = 75
    }
  ) `
  -BlockAccess $false `
  -GenerateAlert "SiteAdmin" `
  -Comment "Audits content with medium-confidence sensitive data matches"

# Rule 3: Audit all AI agent interactions (baseline monitoring)
New-DlpComplianceRule `
  -Name "Audit All AI Agent Interactions" `
  -Policy "A365 Gateway Content Protection" `
  -ContentContainsSensitiveInformation @(
    @{
      Name = "All Full Names"
      MinCount = 1
      MaxConfidence = 100
      MinConfidence = 50
    }
  ) `
  -BlockAccess $false `
  -ReportSeverityLevel "Low" `
  -Comment "Baseline audit for all AI agent content processing"
```

### 2.3 Advanced: Custom Sensitive Information Types

For organization-specific content patterns (e.g., internal project codes, proprietary data formats):

```powershell
# Create a custom sensitive information type
New-DlpSensitiveInformationType `
  -Name "Internal Project Code" `
  -Description "Matches internal project codes in format PRJ-XXXX-YYYY" `
  -SensitiveInformationTypeRulePackage @{
    RulePackage = @{
      RulePack = @{
        Rules = @(
          @{
            Entity = @{
              Id = [guid]::NewGuid().ToString()
              Name = "Internal Project Code"
              Pattern = @(
                @{
                  ConfidenceLevel = 85
                  Match = @{
                    Regex = @{
                      Value = "PRJ-[A-Z]{4}-[0-9]{4}"
                    }
                  }
                }
              )
            }
          }
        )
      }
    }
  }
```

### Verification -- Step 2

```powershell
# List DLP policies
Get-DlpCompliancePolicy | Format-Table Name, Mode, Enabled

# List DLP rules for the policy
Get-DlpComplianceRule -Policy "A365 Gateway Content Protection" |
  Format-Table Name, BlockAccess, ContentContainsSensitiveInformation

# Check policy status
Get-DlpCompliancePolicy -Identity "A365 Gateway Content Protection" |
  Format-List Name, Mode, Enabled, ExchangeLocation, DistributionStatus
```

> **Important:** DLP policies can take up to 24 hours to fully propagate after creation or modification. For immediate testing, wait at least 1 hour.

---

## Step 3: Configure the Gateway's Purview Settings

The gateway supports two Purview modes per agent, configured in the `AgentRegistration` entity:

| Mode | Behavior |
|---|---|
| `AuditOnly` | Evaluate content and submit audit records. Do not block content. If Purview is unavailable, process the activity and queue the audit for bounded retry (max 3 attempts). |
| `Enforce` | Evaluate content inline before processing. Block content that violates DLP policies. If Purview is unavailable, **fail closed** (return 503 `PURVIEW_DEPENDENCY_UNAVAILABLE`). |

### 3.1 Application Configuration

The gateway's `appsettings.json` (or environment variables in Container Apps) controls the global Purview settings:

```json
{
  "Purview": {
    "DefaultMode": "AuditOnly",
    "GraphBaseUrl": "https://graph.microsoft.com/v1.0",
    "ProtectionScopeCacheTtlMinutes": 60,
    "MaxAuditRetryCount": 3,
    "RetryBaseDelaySeconds": 2,
    "EnableContentActivitySubmission": true
  }
}
```

| Setting | Description | Recommended Value |
|---|---|---|
| `DefaultMode` | Default Purview mode for new agent registrations | `AuditOnly` for initial rollout |
| `ProtectionScopeCacheTtlMinutes` | How long to cache protection scope results per user | `60` (1 hour) |
| `MaxAuditRetryCount` | Maximum retries for failed audit submissions in AuditOnly mode | `3` |
| `RetryBaseDelaySeconds` | Base delay for exponential backoff on audit retries | `2` |
| `EnableContentActivitySubmission` | Whether to submit `contentActivities` records to Purview | `true` |

### 3.2 Per-Agent Configuration

Each agent's Purview settings are configured during registration or updated via the management API:

```bash
# Enable Purview in Enforce mode for a specific agent (via gateway API)
curl -X PATCH "https://{gatewayDomain}/api/v1/agents/{agentId}/features" \
  -H "Authorization: Bearer {adminToken}" \
  -H "Content-Type: application/json" \
  -d '{
    "purviewEnabled": true,
    "purviewMode": "Enforce"
  }'
```

### 3.3 Rollout Strategy

1. **Phase 1:** Deploy with `AuditOnly` mode for all agents. Monitor Purview decisions in the gateway database and App Insights for 2 weeks.
2. **Phase 2:** Review audit results. Tune DLP policies to reduce false positives.
3. **Phase 3:** Switch high-sensitivity agents to `Enforce` mode. Keep low-risk agents in `AuditOnly`.
4. **Phase 4:** Enable `Enforce` for all production agents after policy tuning is complete.

---

## Step 4: Grant Purview API Permissions

The gateway calls two Microsoft Graph API endpoints for Purview evaluation. These require specific application permissions.

### 4.1 Required Permissions

| API Endpoint | Permission | Type | Description |
|---|---|---|---|
| `POST /users/{userId}/dataSecurityAndGovernance/protectionScopes/compute` | `DataSecurityAndGovernance.Scoping.Read.All` | Application | Determine which policies apply to a user |
| `POST /users/{userId}/dataSecurityAndGovernance/processContent` | `DataSecurityAndGovernance.Content.Process.All` | Application | Evaluate content against DLP policies |
| `POST /users/{userId}/dataSecurityAndGovernance/activities/contentActivities` | `ContentActivity.Write` | Application | Submit content activity audit records |

### 4.2 Grant Permissions to the Gateway API's Managed Identity

Since the gateway uses system-assigned managed identity, permissions are granted to the managed identity's service principal via Microsoft Graph PowerShell:

```powershell
# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All"

# Get the Microsoft Graph service principal
$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

# Get the gateway API's managed identity service principal
$gatewayApiSp = Get-MgServicePrincipal -Filter "displayName eq '{gatewayApiContainerAppName}'"

# Get the worker's managed identity service principal
$workerSp = Get-MgServicePrincipal -Filter "displayName eq '{workerContainerAppName}'"

# Find the required app role IDs
$scopingRole = $graphSp.AppRoles | Where-Object { $_.Value -eq "DataSecurityAndGovernance.Scoping.Read.All" }
$processContentRole = $graphSp.AppRoles | Where-Object { $_.Value -eq "DataSecurityAndGovernance.Content.Process.All" }
$contentActivityRole = $graphSp.AppRoles | Where-Object { $_.Value -eq "ContentActivity.Write" }

# Assign permissions to the Gateway API managed identity
# processContent (inline evaluation during API requests)
New-MgServicePrincipalAppRoleAssignment `
  -ServicePrincipalId $gatewayApiSp.Id `
  -PrincipalId $gatewayApiSp.Id `
  -ResourceId $graphSp.Id `
  -AppRoleId $processContentRole.Id

New-MgServicePrincipalAppRoleAssignment `
  -ServicePrincipalId $gatewayApiSp.Id `
  -PrincipalId $gatewayApiSp.Id `
  -ResourceId $graphSp.Id `
  -AppRoleId $scopingRole.Id

# Assign permissions to the Worker managed identity
# contentActivities (async audit submission)
New-MgServicePrincipalAppRoleAssignment `
  -ServicePrincipalId $workerSp.Id `
  -PrincipalId $workerSp.Id `
  -ResourceId $graphSp.Id `
  -AppRoleId $contentActivityRole.Id

New-MgServicePrincipalAppRoleAssignment `
  -ServicePrincipalId $workerSp.Id `
  -PrincipalId $workerSp.Id `
  -ResourceId $graphSp.Id `
  -AppRoleId $processContentRole.Id

New-MgServicePrincipalAppRoleAssignment `
  -ServicePrincipalId $workerSp.Id `
  -PrincipalId $workerSp.Id `
  -ResourceId $graphSp.Id `
  -AppRoleId $scopingRole.Id
```

### Verification -- Step 4

```powershell
# Verify permissions assigned to gateway API managed identity
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $gatewayApiSp.Id |
  Select-Object AppRoleId, ResourceDisplayName, PrincipalDisplayName |
  Format-Table

# Verify permissions assigned to worker managed identity
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $workerSp.Id |
  Select-Object AppRoleId, ResourceDisplayName, PrincipalDisplayName |
  Format-Table
```

Confirm that both managed identities have the expected Graph permissions.

---

## Step 5: Test Policy Evaluation

### 5.1 Test Protection Scope Computation

Use the Microsoft Graph Explorer or `curl` to test that the gateway's managed identity can compute protection scopes:

```bash
# Acquire a token using the managed identity (run from within the Container App)
TOKEN=$(curl -s -H "Metadata: true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://graph.microsoft.com" \
  | jq -r '.access_token')

# Compute protection scope for a test user
curl -X POST "https://graph.microsoft.com/v1.0/users/{testUserObjectId}/dataSecurityAndGovernance/protectionScopes/compute" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "appId": "{gatewayApiClientId}"
  }'
```

Expected response:

```json
{
  "executionMode": "evaluateInline",
  "protectionScopeId": "...",
  "@odata.etag": "..."
}
```

### 5.2 Test Content Processing

```bash
# Test processContent with sample content
curl -X POST "https://graph.microsoft.com/v1.0/users/{testUserObjectId}/dataSecurityAndGovernance/processContent" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "appId": "{gatewayApiClientId}",
    "protectionScopeId": "{protectionScopeIdFromStep5.1}",
    "activities": [
      {
        "type": "prompt",
        "content": "This is a test prompt that does not contain sensitive information."
      }
    ]
  }'
```

Expected response for non-sensitive content:

```json
{
  "policyActions": []
}
```

### 5.3 Test DLP Policy Trigger

```bash
# Test with content that should trigger DLP (use fake test data)
curl -X POST "https://graph.microsoft.com/v1.0/users/{testUserObjectId}/dataSecurityAndGovernance/processContent" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "appId": "{gatewayApiClientId}",
    "protectionScopeId": "{protectionScopeIdFromStep5.1}",
    "activities": [
      {
        "type": "prompt",
        "content": "Please process the following credit card: 4111-1111-1111-1111"
      }
    ]
  }'
```

Expected response (should contain a block or restrict action):

```json
{
  "policyActions": [
    {
      "type": "restrictAccess",
      "details": "..."
    }
  ]
}
```

### 5.4 Test via the Gateway API

After the gateway is deployed, test end-to-end through the gateway's AI interaction endpoint:

```bash
# Acquire an external agent token
AGENT_TOKEN=$(curl -s -X POST "https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/token" \
  -d "client_id={externalAgentClientId}" \
  -d "client_secret={secret}" \
  -d "scope=api://{gatewayApiClientId}/.default" \
  -d "grant_type=client_credentials" | jq -r '.access_token')

# Submit an AI interaction for evaluation
curl -X POST "https://{gatewayDomain}/api/v1/ai-interactions:evaluate" \
  -H "Authorization: Bearer $AGENT_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: $(uuidgen)" \
  -d '{
    "externalAgentId": "{externalAgentId}",
    "userContext": {
      "tenantUserObjectId": "{testUserObjectId}"
    },
    "prompt": "Test prompt for Purview evaluation",
    "response": "Test response content"
  }'
```

### Verification -- Step 5

| Test Case | Expected Result |
|---|---|
| Protection scope computation | Returns `executionMode` and `protectionScopeId` |
| Non-sensitive content | Empty `policyActions` array |
| Sensitive content (credit card) | `policyActions` contains `restrictAccess` or `block` |
| Gateway AI interaction (Enforce, blocked) | HTTP 403 with `PURVIEW_POLICY_BLOCKED` error code |
| Gateway AI interaction (Enforce, allowed) | HTTP 200 with `decision: Allow` |
| Gateway AI interaction (AuditOnly) | HTTP 200 (always allowed); audit record submitted asynchronously |
| No user context provided | Purview evaluation skipped; `PurviewSkipped_NoUserContext` logged |

---

## Purview Decision Matrix

For reference, the gateway evaluates Purview according to this decision matrix (from the architecture specification):

| Agent Config | User Context | Purview API Available | Gateway Action |
|---|---|---|---|
| `purviewEnabled=false` | N/A | N/A | Skip. Log `PurviewDisabled`. |
| `purviewEnabled=true`, `Enforce` | Missing | N/A | Skip Purview. Log `PurviewSkipped_NoUserContext`. Process activity. |
| `purviewEnabled=true`, `Enforce` | Present | Available | Evaluate inline. Block or allow per `policyActions`. |
| `purviewEnabled=true`, `Enforce` | Present | **Unavailable** | **Fail closed.** Return 503 `PURVIEW_DEPENDENCY_UNAVAILABLE`. Do not process. |
| `purviewEnabled=true`, `AuditOnly` | Missing | N/A | Skip Purview. Log `PurviewSkipped_NoUserContext`. Process activity. |
| `purviewEnabled=true`, `AuditOnly` | Present | Available | Process activity. Submit audit record asynchronously. |
| `purviewEnabled=true`, `AuditOnly` | Present | **Unavailable** | Process activity. Queue audit for bounded retry (max 3). |

---

## Ongoing Operations

### Monitor Purview Decisions

```kusto
// KQL query for Application Insights - Purview decision distribution
customEvents
| where name == "PurviewDecision"
| summarize count() by tostring(customDimensions["decision"]), bin(timestamp, 1h)
| render timechart
```

### Review DLP Policy Matches

```powershell
# Check DLP policy matches in Security & Compliance
Get-DlpDetailReport -StartDate (Get-Date).AddDays(-7) -EndDate (Get-Date) |
  Where-Object { $_.Policy -eq "A365 Gateway Content Protection" } |
  Format-Table Date, Policy, Rule, SensitiveInformationType, Action
```

### Update DLP Rules

```powershell
# Modify an existing DLP rule (e.g., adjust confidence threshold)
Set-DlpComplianceRule `
  -Identity "Block Highly Sensitive Content" `
  -ContentContainsSensitiveInformation @(
    @{
      Name = "Credit Card Number"
      MinCount = 1
      MaxConfidence = 100
      MinConfidence = 90
    }
  )
```

> Policy changes take up to 24 hours to propagate. Test in a non-production environment first.

---

## Troubleshooting

| Issue | Cause | Resolution |
|---|---|---|
| `403` from `protectionScopes/compute` | Missing `DataSecurityAndGovernance.Scoping.Read.All` permission | Grant the permission per Step 4 |
| `403` from `processContent` | Missing `DataSecurityAndGovernance.Content.Process.All` permission | Grant the permission per Step 4 |
| Empty `policyActions` for known-sensitive content | DLP policy not yet propagated, or rule confidence threshold not met | Wait 24 hours after policy creation; check rule confidence levels |
| `404` for `/users/{userId}` | Invalid `tenantUserObjectId` | Verify the user exists in the tenant |
| Gateway returns `503 PURVIEW_DEPENDENCY_UNAVAILABLE` | Purview API is down; agent is in Enforce mode | Temporarily switch to AuditOnly mode, or wait for Purview recovery |
| PowerShell `Connect-IPPSSession` fails | MFA or Conditional Access blocking | Use `-UserPrincipalName` parameter; ensure the account has Compliance Administrator role |
| DLP policy shows `DistributionStatus: Pending` | Policy is still propagating | Wait up to 24 hours; check status with `Get-DlpCompliancePolicy` |
