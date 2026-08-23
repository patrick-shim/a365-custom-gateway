# Phase 3: API Contract

## 1. Endpoint Catalog

All endpoints are **gateway-owned APIs designed for this solution, not Microsoft APIs.**

Base path: `/api/v1`

Content type: `application/json`

Timestamps: UTC ISO 8601

Identifiers: UUID (gateway-generated), string (external agent IDs)

### 1.1 Control-Plane Endpoints

| # | Method | Path | Description | Auth Roles | Idempotency | Concurrency |
|---|---|---|---|---|---|---|
| 1 | `POST` | `/agents` | Register a new external agent | `Gateway.Administrator` | — | Unique `externalAgentId` constraint |
| 2 | `GET` | `/agents` | List agents (filtered, paged) | `Gateway.Administrator`, `Gateway.Operator`, `Gateway.Auditor`, `Gateway.SupportReader` | — | — |
| 3 | `GET` | `/agents/{agentId}` | Get agent details | `Gateway.Administrator`, `Gateway.Operator`, `Gateway.Auditor`, `Gateway.SupportReader` | — | — |
| 4 | `PATCH` | `/agents/{agentId}/features` | Update feature configuration | `Gateway.Administrator` | — | `If-Match` (ETag/rowVersion) |
| 5 | `POST` | `/agents/{agentId}:enable` | Enable an agent | `Gateway.Administrator`, `Gateway.Operator` | `Idempotency-Key` | — |
| 6 | `POST` | `/agents/{agentId}:disable` | Disable an agent | `Gateway.Administrator`, `Gateway.Operator` | `Idempotency-Key` | — |
| 7 | `DELETE` | `/agents/{agentId}` | Delete an agent (async) | `Gateway.Administrator` | `Idempotency-Key` | `If-Match` (ETag/rowVersion) |
| 8 | `POST` | `/agents/{agentId}:retry-provisioning` | Retry failed provisioning | `Gateway.Administrator` | `Idempotency-Key` | — |
| 9 | `POST` | `/agents/{agentId}:reconcile` | Trigger on-demand reconciliation | `Gateway.Administrator` | `Idempotency-Key` | — |
| 10 | `GET` | `/operations/{operationId}` | Get operation status | `Gateway.Administrator`, `Gateway.Operator` | — | — |
| 11 | `GET` | `/agents/{agentId}/audit-events` | Get agent audit history | `Gateway.Administrator`, `Gateway.Auditor` | — | — |
| 12 | `GET` | `/agents/{agentId}/provisioning-history` | Get provisioning job history | `Gateway.Administrator`, `Gateway.Operator` | — | — |
| 13 | `GET` | `/system/config` | Get system configuration | `Gateway.Administrator` | — | — |
| 14 | `PATCH` | `/system/config` | Update system configuration | `Gateway.Administrator` | — | `If-Match` |
| 15 | `GET` | `/health` | Health check (liveness) | Anonymous | — | — |
| 16 | `GET` | `/health/ready` | Readiness check | Anonymous | — | — |

### 1.2 Data-Plane Endpoints

| # | Method | Path | Description | Auth Roles | Idempotency | Concurrency |
|---|---|---|---|---|---|---|
| 17 | `POST` | `/agent-activities` | Submit a single activity | `ExternalAgent` | `Idempotency-Key` (required) | — |
| 18 | `POST` | `/agent-activities:batch` | Submit a batch of activities | `ExternalAgent` | `Idempotency-Key` (required) | — |
| 19 | `POST` | `/ai-interactions` | Submit an AI interaction (async) | `ExternalAgent` | `Idempotency-Key` (required) | — |
| 20 | `POST` | `/ai-interactions:evaluate` | Evaluate interaction inline (Purview enforce) | `ExternalAgent` | `Idempotency-Key` (required) | — |

---

## 2. Authentication and Authorization Rules

### 2.1 Security Schemes

| Scheme | Type | Description | Used By |
|---|---|---|---|
| `EntraInteractive` | OpenID Connect (auth code flow) | Admin users sign in via Entra ID. ID token + access token with delegated scopes. | AdminUI → API |
| `EntraAppRole` | OAuth 2.0 Bearer (client credentials) | External agents authenticate with their own Entra app registration. Token contains `ExternalAgent` app role. | External agents → API |

### 2.2 Token Validation

All requests (except `/health` and `/health/ready`) require a valid Bearer token validated by Microsoft Identity Web:

| Check | Detail |
|---|---|
| Signature | RS256, validated against Entra ID OIDC metadata keys |
| Issuer | `https://login.microsoftonline.com/{tenantId}/v2.0` or v1.0 equivalent |
| Audience | Gateway API application ID |
| Expiry | `exp` claim must be in the future |
| Roles | `roles` claim must contain one of the required roles for the endpoint |

### 2.3 Per-Endpoint Authorization Matrix

| Endpoint | Gateway.Administrator | Gateway.Operator | Gateway.Auditor | Gateway.SupportReader | ExternalAgent |
|---|---|---|---|---|---|
| `POST /agents` | Yes | — | — | — | — |
| `GET /agents` | Yes | Yes | Yes | Yes (redacted) | — |
| `GET /agents/{agentId}` | Yes | Yes | Yes | Yes (redacted) | — |
| `PATCH /agents/{agentId}/features` | Yes | — | — | — | — |
| `POST /agents/{agentId}:enable` | Yes | Yes | — | — | — |
| `POST /agents/{agentId}:disable` | Yes | Yes | — | — | — |
| `DELETE /agents/{agentId}` | Yes | — | — | — | — |
| `POST /agents/{agentId}:retry-provisioning` | Yes | — | — | — | — |
| `POST /agents/{agentId}:reconcile` | Yes | — | — | — | — |
| `GET /operations/{operationId}` | Yes | Yes | — | — | — |
| `GET /agents/{agentId}/audit-events` | Yes | — | Yes | — | — |
| `GET /agents/{agentId}/provisioning-history` | Yes | Yes | — | — | — |
| `GET /system/config` | Yes | — | — | — | — |
| `PATCH /system/config` | Yes | — | — | — | — |
| `POST /agent-activities` | — | — | — | — | Yes |
| `POST /agent-activities:batch` | — | — | — | — | Yes |
| `POST /ai-interactions` | — | — | — | — | Yes |
| `POST /ai-interactions:evaluate` | — | — | — | — | Yes |

### 2.4 Data-Plane Identity Binding

For all `ExternalAgent` endpoints, the gateway enforces agent-to-client identity binding:

1. Extract `appid` (v1 token) or `azp` (v2 token) from the bearer token.
2. Look up `AgentRegistration` where `externalClientId == appid/azp`.
3. Compare `externalAgentId` from the request body against the bound registration.
4. If mismatch → `403 AGENT_IDENTITY_MISMATCH`.
5. If agent status ≠ `Active` → `403 AGENT_DISABLED` (or appropriate error).

### 2.5 SupportReader Redaction

When `Gateway.SupportReader` accesses agent data, the following fields are redacted:

- `ownerObjectId` → `"[REDACTED]"`
- `externalClientId` → `"[REDACTED]"`
- `agent365AgentId` → last 4 characters only
- `blueprintId` → last 4 characters only
- Audit event details containing user identifiers → redacted

---

## 3. Request/Response Schemas

### 3.1 Register Agent

**Request:** `POST /api/v1/agents`

```json
{
  "externalAgentId": "crm-assistant-prod",
  "name": "CRM Assistant",
  "description": "Answers customer and sales questions.",
  "ownerObjectId": "00000000-0000-0000-0000-000000000001",
  "environment": "Production",
  "features": {
    "observabilityMode": "Agent365",
    "purviewEnabled": true,
    "purviewMode": "Enforce"
  }
}
```

| Field | Type | Required | Constraints |
|---|---|---|---|
| `externalAgentId` | string | Yes | 3-128 chars, `^[a-zA-Z0-9][a-zA-Z0-9._-]*$`, unique, immutable |
| `name` | string | Yes | 1-256 chars |
| `description` | string | No | 0-2000 chars |
| `ownerObjectId` | string (UUID) | Yes | Valid Entra user object ID |
| `environment` | enum | Yes | `Development`, `Test`, `Production` |
| `features.observabilityMode` | enum | No | `Disabled`, `GatewayOnly`, `Agent365`. Default: `GatewayOnly` |
| `features.purviewEnabled` | boolean | No | Default: `false` |
| `features.purviewMode` | enum | Conditional | Required when `purviewEnabled=true`. `AuditOnly`, `Enforce` |

**Response:** `202 Accepted`

```json
{
  "agentId": "3d62b161-e342-4cc5-bd3e-e98fa91431df",
  "externalAgentId": "crm-assistant-prod",
  "name": "CRM Assistant",
  "status": "Provisioning",
  "operationId": "31395296-1962-4ed4-963c-d1546dd274b1",
  "createdAtUtc": "2026-08-23T04:30:00Z",
  "_links": {
    "self": "/api/v1/agents/3d62b161-e342-4cc5-bd3e-e98fa91431df",
    "operation": "/api/v1/operations/31395296-1962-4ed4-963c-d1546dd274b1"
  }
}
```

**Headers:**
- `Location: /api/v1/agents/{agentId}`
- `Operation-Location: /api/v1/operations/{operationId}`

### 3.2 List Agents

**Request:** `GET /api/v1/agents?status=Active&environment=Production&search=crm&limit=50&cursor={cursor}`

| Parameter | Type | Description |
|---|---|---|
| `status` | enum | Filter by agent status |
| `environment` | enum | Filter by environment |
| `search` | string | Search in name, externalAgentId, description |
| `limit` | integer | Page size, 1-100, default 25 |
| `cursor` | string | Opaque cursor from previous response |

**Response:** `200 OK`

```json
{
  "items": [
    {
      "agentId": "3d62b161-e342-4cc5-bd3e-e98fa91431df",
      "externalAgentId": "crm-assistant-prod",
      "name": "CRM Assistant",
      "description": "Answers customer and sales questions.",
      "status": "Active",
      "environment": "Production",
      "agent365": {
        "agentId": "a365-agent-id",
        "blueprintId": "blueprint-id",
        "instanceId": "instance-id"
      },
      "features": {
        "observabilityMode": "Agent365",
        "purviewEnabled": true,
        "purviewMode": "Enforce"
      },
      "lastActivityAtUtc": "2026-08-23T04:45:00Z",
      "createdAtUtc": "2026-08-23T04:30:00Z",
      "updatedAtUtc": "2026-08-23T04:35:00Z"
    }
  ],
  "nextCursor": "eyJpZCI6IjNkNjJiMTYxLWUzNDItNGNjNS1iZDNlLWU5OGZhOTE0MzFkZiJ9",
  "totalCount": 42
}
```

### 3.3 Get Agent

**Request:** `GET /api/v1/agents/{agentId}`

**Response:** `200 OK`

```json
{
  "agentId": "3d62b161-e342-4cc5-bd3e-e98fa91431df",
  "externalAgentId": "crm-assistant-prod",
  "name": "CRM Assistant",
  "description": "Answers customer and sales questions.",
  "ownerObjectId": "00000000-0000-0000-0000-000000000001",
  "status": "Active",
  "environment": "Production",
  "agent365": {
    "agentId": "a365-agent-id",
    "blueprintId": "blueprint-id",
    "instanceId": "instance-id"
  },
  "features": {
    "observabilityMode": "Agent365",
    "purviewEnabled": true,
    "purviewMode": "Enforce"
  },
  "provisioningStatus": {
    "currentStep": "Completed",
    "percentComplete": 100,
    "lastError": null
  },
  "lastActivityAtUtc": "2026-08-23T04:45:00Z",
  "createdAtUtc": "2026-08-23T04:30:00Z",
  "createdByObjectId": "00000000-0000-0000-0000-000000000001",
  "updatedAtUtc": "2026-08-23T04:35:00Z",
  "updatedByObjectId": "00000000-0000-0000-0000-000000000001",
  "rowVersion": "AAAAAAAAB9E=",
  "_links": {
    "self": "/api/v1/agents/3d62b161-e342-4cc5-bd3e-e98fa91431df",
    "features": "/api/v1/agents/3d62b161-e342-4cc5-bd3e-e98fa91431df/features",
    "auditEvents": "/api/v1/agents/3d62b161-e342-4cc5-bd3e-e98fa91431df/audit-events",
    "provisioningHistory": "/api/v1/agents/3d62b161-e342-4cc5-bd3e-e98fa91431df/provisioning-history"
  }
}
```

**Headers:**
- `ETag: "AAAAAAAAB9E="`

### 3.4 Update Feature Configuration

**Request:** `PATCH /api/v1/agents/{agentId}/features`

**Headers:** `If-Match: "AAAAAAAAB9E="`

```json
{
  "observabilityMode": "Agent365",
  "purviewEnabled": false
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `observabilityMode` | enum | No | `Disabled`, `GatewayOnly`, `Agent365` |
| `purviewEnabled` | boolean | No | |
| `purviewMode` | enum | No | Required if `purviewEnabled` is being set to `true` |

**Response:** `200 OK`

```json
{
  "agentId": "3d62b161-e342-4cc5-bd3e-e98fa91431df",
  "features": {
    "observabilityMode": "Agent365",
    "purviewEnabled": false,
    "purviewMode": null
  },
  "updatedAtUtc": "2026-08-23T04:40:00Z",
  "rowVersion": "AAAAAAAAB9I="
}
```

**Headers:**
- `ETag: "AAAAAAAAB9I="`

### 3.5 Enable Agent

**Request:** `POST /api/v1/agents/{agentId}:enable`

**Headers:** `Idempotency-Key: 550e8400-e29b-41d4-a716-446655440000`

**Response:** `200 OK`

```json
{
  "agentId": "3d62b161-e342-4cc5-bd3e-e98fa91431df",
  "status": "Active",
  "effectiveAtUtc": "2026-08-23T04:40:00Z"
}
```

### 3.6 Disable Agent

**Request:** `POST /api/v1/agents/{agentId}:disable`

**Headers:** `Idempotency-Key: 550e8400-e29b-41d4-a716-446655440001`

**Response:** `200 OK`

```json
{
  "agentId": "3d62b161-e342-4cc5-bd3e-e98fa91431df",
  "status": "Disabled",
  "effectiveAtUtc": "2026-08-23T04:41:00Z"
}
```

### 3.7 Delete Agent

**Request:** `DELETE /api/v1/agents/{agentId}?deleteMicrosoftResources=false`

**Headers:**
- `If-Match: "AAAAAAAAB9E="`
- `Idempotency-Key: 550e8400-e29b-41d4-a716-446655440002`

**Response:** `202 Accepted`

```json
{
  "agentId": "3d62b161-e342-4cc5-bd3e-e98fa91431df",
  "status": "Deleting",
  "operationId": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "deleteMicrosoftResources": false,
  "_links": {
    "operation": "/api/v1/operations/f47ac10b-58cc-4372-a567-0e02b2c3d479"
  }
}
```

### 3.8 Retry Provisioning

**Request:** `POST /api/v1/agents/{agentId}:retry-provisioning`

**Headers:** `Idempotency-Key: 550e8400-e29b-41d4-a716-446655440003`

Precondition: Agent must be in `Failed` status.

**Response:** `202 Accepted`

```json
{
  "agentId": "3d62b161-e342-4cc5-bd3e-e98fa91431df",
  "status": "Provisioning",
  "operationId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "_links": {
    "operation": "/api/v1/operations/a1b2c3d4-e5f6-7890-abcd-ef1234567890"
  }
}
```

### 3.9 Reconcile Agent

**Request:** `POST /api/v1/agents/{agentId}:reconcile`

**Headers:** `Idempotency-Key: 550e8400-e29b-41d4-a716-446655440004`

Precondition: Agent must be in `Active`, `Disabled`, or `AwaitingAdminApproval` status.

**Response:** `202 Accepted`

```json
{
  "agentId": "3d62b161-e342-4cc5-bd3e-e98fa91431df",
  "operationId": "b2c3d4e5-f6a7-8901-bcde-f12345678901",
  "_links": {
    "operation": "/api/v1/operations/b2c3d4e5-f6a7-8901-bcde-f12345678901"
  }
}
```

### 3.10 Get Operation Status

**Request:** `GET /api/v1/operations/{operationId}`

**Response:** `200 OK`

```json
{
  "operationId": "31395296-1962-4ed4-963c-d1546dd274b1",
  "type": "ProvisionAgent",
  "status": "Running",
  "currentStep": "CreatingBlueprint",
  "percentComplete": 60,
  "agentId": "3d62b161-e342-4cc5-bd3e-e98fa91431df",
  "startedAtUtc": "2026-08-23T04:30:01Z",
  "completedAtUtc": null,
  "error": null,
  "steps": [
    { "step": "CreateAppRegistration", "status": "Completed", "completedAtUtc": "2026-08-23T04:30:05Z" },
    { "step": "CreateServicePrincipal", "status": "Completed", "completedAtUtc": "2026-08-23T04:30:08Z" },
    { "step": "AssignRoles", "status": "Completed", "completedAtUtc": "2026-08-23T04:30:10Z" },
    { "step": "StoreCredentials", "status": "Completed", "completedAtUtc": "2026-08-23T04:30:12Z" },
    { "step": "CreateBlueprint", "status": "Running", "completedAtUtc": null },
    { "step": "CreateBlueprintPrincipal", "status": "Pending", "completedAtUtc": null },
    { "step": "RegisterAgent", "status": "Pending", "completedAtUtc": null }
  ]
}
```

**Operation types:** `ProvisionAgent`, `DeleteAgent`, `RetryProvisioning`, `ReconcileAgent`

**Operation statuses:** `Pending`, `Running`, `Completed`, `Failed`, `RequiresManualIntervention`

### 3.11 Get Audit Events

**Request:** `GET /api/v1/agents/{agentId}/audit-events?limit=25&cursor={cursor}`

**Response:** `200 OK`

```json
{
  "items": [
    {
      "eventId": "e1225adb-28f9-4a20-b821-749a00863df7",
      "agentId": "3d62b161-e342-4cc5-bd3e-e98fa91431df",
      "eventType": "AgentRegistered",
      "performedByObjectId": "00000000-0000-0000-0000-000000000001",
      "occurredAtUtc": "2026-08-23T04:30:00Z",
      "details": {
        "externalAgentId": "crm-assistant-prod",
        "environment": "Production"
      }
    }
  ],
  "nextCursor": null
}
```

**Event types:** `AgentRegistered`, `AgentActivated`, `AgentDisabled`, `AgentEnabled`, `AgentDeleted`, `ProvisioningStarted`, `ProvisioningCompleted`, `ProvisioningFailed`, `ProvisioningRetried`, `FeaturesUpdated`, `ReconciliationCompleted`, `ReconciliationDriftDetected`, `ManualResolutionCompleted`, `CredentialRotated`, `SystemConfigUpdated`

### 3.12 Get Provisioning History

**Request:** `GET /api/v1/agents/{agentId}/provisioning-history?limit=10&cursor={cursor}`

**Response:** `200 OK`

```json
{
  "items": [
    {
      "jobId": "31395296-1962-4ed4-963c-d1546dd274b1",
      "agentId": "3d62b161-e342-4cc5-bd3e-e98fa91431df",
      "type": "ProvisionAgent",
      "status": "Completed",
      "startedAtUtc": "2026-08-23T04:30:01Z",
      "completedAtUtc": "2026-08-23T04:35:00Z",
      "steps": [
        { "step": "CreateAppRegistration", "status": "Completed" },
        { "step": "CreateServicePrincipal", "status": "Completed" },
        { "step": "AssignRoles", "status": "Completed" },
        { "step": "StoreCredentials", "status": "Completed" },
        { "step": "CreateBlueprint", "status": "Completed" },
        { "step": "CreateBlueprintPrincipal", "status": "Completed" },
        { "step": "RegisterAgent", "status": "Completed" }
      ],
      "error": null
    }
  ],
  "nextCursor": null
}
```

### 3.13 System Configuration

**Request:** `GET /api/v1/system/config`

**Response:** `200 OK`

```json
{
  "tenantId": "ff8b1e46-ff0f-4bc2-ab02-caf2b92da496",
  "provisioningMode": "Automatic",
  "defaultObservabilityMode": "GatewayOnly",
  "defaultPurviewEnabled": false,
  "defaultPurviewMode": "AuditOnly",
  "retentionDays": {
    "activityReceipts": 90,
    "auditEvents": 365,
    "idempotencyRecords": 7,
    "outboxMessages": 3
  },
  "rateLimits": {
    "perClientRequestsPerMinute": 600,
    "perAgentRequestsPerMinute": 300,
    "globalRequestsPerMinute": 10000
  },
  "reconciliation": {
    "enabled": true,
    "intervalHours": 6,
    "stuckTransitionTimeoutDays": 7
  },
  "featureFlags": {
    "useGraphAgentRegistration": true,
    "useCliProvisioningFallback": true
  },
  "rowVersion": "AAAAAAAAB9M=",
  "updatedAtUtc": "2026-08-23T04:00:00Z"
}
```

### 3.14 Submit Activity

**Request:** `POST /api/v1/agent-activities`

**Headers:**
- `Authorization: Bearer {token}`
- `Idempotency-Key: 550e8400-e29b-41d4-a716-446655440010`
- `X-Correlation-ID: 0dccba49-df57-4274-9332-137799481b89`

```json
{
  "externalAgentId": "crm-assistant-prod",
  "activityId": "ext-activity-45892",
  "sessionId": "session-12345",
  "activityType": "ToolInvocation",
  "occurredAtUtc": "2026-08-23T04:45:00Z",
  "actor": {
    "type": "Agent"
  },
  "tool": {
    "name": "CustomerLookup",
    "operation": "GetCustomerSummary",
    "outcome": "Succeeded",
    "durationMs": 218
  },
  "attributes": {
    "sourceFramework": "Custom"
  }
}
```

| Field | Type | Required | Constraints |
|---|---|---|---|
| `externalAgentId` | string | Yes | Must match identity binding |
| `activityId` | string | Yes | 1-256 chars, unique per agent |
| `sessionId` | string | No | 1-256 chars |
| `activityType` | enum | Yes | `ToolInvocation`, `Chat`, `InvokeAgent`, `OutputMessages`, `Custom` |
| `occurredAtUtc` | datetime | Yes | ISO 8601 UTC, not in the future |
| `actor.type` | enum | Yes | `Agent`, `User`, `System` |
| `tool` | object | Conditional | Required when `activityType=ToolInvocation` |
| `tool.name` | string | Yes | 1-256 chars |
| `tool.operation` | string | No | 1-256 chars |
| `tool.outcome` | enum | Yes | `Succeeded`, `Failed`, `Cancelled` |
| `tool.durationMs` | integer | No | >= 0 |
| `attributes` | object | No | Max 20 keys, key max 64 chars, value max 256 chars |

**Response:** `202 Accepted`

```json
{
  "receiptId": "6b58517d-c60e-4da8-8914-a70a5e724d16",
  "activityId": "ext-activity-45892",
  "status": "Accepted",
  "receivedAtUtc": "2026-08-23T04:45:01Z",
  "correlationId": "0dccba49-df57-4274-9332-137799481b89"
}
```

### 3.15 Batch Activities

**Request:** `POST /api/v1/agent-activities:batch`

**Headers:**
- `Idempotency-Key: 550e8400-e29b-41d4-a716-446655440011`

```json
{
  "externalAgentId": "crm-assistant-prod",
  "activities": [
    {
      "activityId": "event-1",
      "sessionId": "session-12345",
      "activityType": "ToolInvocation",
      "occurredAtUtc": "2026-08-23T04:45:00Z",
      "actor": { "type": "Agent" },
      "tool": { "name": "CustomerLookup", "operation": "Get", "outcome": "Succeeded", "durationMs": 218 }
    },
    {
      "activityId": "event-2",
      "sessionId": "session-12345",
      "activityType": "Chat",
      "occurredAtUtc": "2026-08-23T04:45:01Z",
      "actor": { "type": "User" }
    }
  ]
}
```

| Limit | Value |
|---|---|
| Max events per batch | 100 |
| Max request body size | 1 MB |
| Partial success | Supported — each item gets its own status |

**Response:** `200 OK` (partial success) or `202 Accepted` (all accepted)

```json
{
  "accepted": 1,
  "rejected": 1,
  "items": [
    {
      "activityId": "event-1",
      "status": "Accepted",
      "receiptId": "6b58517d-c60e-4da8-8914-a70a5e724d17"
    },
    {
      "activityId": "event-2",
      "status": "Rejected",
      "code": "VALIDATION_FAILED",
      "detail": "Missing required field: actor.type"
    }
  ],
  "correlationId": "0dccba49-df57-4274-9332-137799481b89"
}
```

### 3.16 Submit AI Interaction (Async)

**Request:** `POST /api/v1/ai-interactions`

**Headers:** `Idempotency-Key: 550e8400-e29b-41d4-a716-446655440012`

```json
{
  "externalAgentId": "crm-assistant-prod",
  "interactionId": "interaction-88731",
  "sessionId": "session-12345",
  "occurredAtUtc": "2026-08-23T04:47:00Z",
  "userContext": {
    "tenantUserObjectId": "00000000-0000-0000-0000-000000000045"
  },
  "prompt": {
    "contentType": "text/plain",
    "content": "Summarize the customer account."
  },
  "response": {
    "contentType": "text/plain",
    "content": "The account is currently active."
  },
  "model": {
    "provider": "ExternalProvider",
    "name": "external-model"
  },
  "metadata": {
    "locale": "en-US"
  }
}
```

| Field | Type | Required | Constraints |
|---|---|---|---|
| `externalAgentId` | string | Yes | Must match identity binding |
| `interactionId` | string | Yes | 1-256 chars, unique per agent |
| `sessionId` | string | No | 1-256 chars |
| `occurredAtUtc` | datetime | Yes | ISO 8601 UTC |
| `userContext.tenantUserObjectId` | string (UUID) | No | Required for Purview evaluation |
| `prompt.contentType` | string | Yes | `text/plain` or `text/markdown` |
| `prompt.content` | string | Yes | Max 32 KB |
| `response.contentType` | string | Yes | `text/plain` or `text/markdown` |
| `response.content` | string | Yes | Max 32 KB |
| `model.provider` | string | No | 1-256 chars |
| `model.name` | string | No | 1-256 chars |
| `metadata` | object | No | Max 20 keys |

**Response:** `202 Accepted`

```json
{
  "receiptId": "e1225adb-28f9-4a20-b821-749a00863df7",
  "interactionId": "interaction-88731",
  "status": "Accepted",
  "purviewProcessing": "Pending",
  "observabilityProcessing": "Pending",
  "correlationId": "c1d2e3f4-a5b6-7890-cdef-123456789012"
}
```

### 3.17 Evaluate AI Interaction Inline (Purview Enforce)

**Request:** `POST /api/v1/ai-interactions:evaluate`

**Headers:** `Idempotency-Key: 550e8400-e29b-41d4-a716-446655440013`

Request body: Same as AI interaction (3.16).

**Response (Allow):** `200 OK`

```json
{
  "interactionId": "interaction-88731",
  "decision": "Allow",
  "policyActions": [],
  "evaluatedAtUtc": "2026-08-23T04:47:01Z",
  "receiptId": "e1225adb-28f9-4a20-b821-749a00863df7",
  "purviewProcessing": "Completed",
  "observabilityProcessing": "Pending"
}
```

**Response (Block):** `403 Forbidden`

```json
{
  "type": "https://gateway.example.com/problems/purview-policy-blocked",
  "title": "Content was blocked by organizational policy.",
  "status": 403,
  "code": "PURVIEW_POLICY_BLOCKED",
  "traceId": "00-abcdef1234567890abcdef1234567890-abcdef1234567890-01",
  "policyActions": [
    {
      "action": "Block"
    }
  ]
}
```

---

## 4. Error Model

All errors use RFC 9457 Problem Details:

```json
{
  "type": "https://gateway.example.com/problems/{error-slug}",
  "title": "Human-readable title.",
  "status": 400,
  "code": "STABLE_ERROR_CODE",
  "detail": "Additional context about the specific error.",
  "traceId": "00-abcdef1234567890abcdef1234567890-abcdef1234567890-01",
  "instance": "/api/v1/agents/3d62b161-e342-4cc5-bd3e-e98fa91431df"
}
```

### Error Code Catalog

| Code | HTTP Status | Description | When |
|---|---|---|---|
| `VALIDATION_FAILED` | 400 | Request validation failed | Invalid field values, missing required fields |
| `AUTHENTICATION_REQUIRED` | 401 | No valid bearer token | Missing or expired token |
| `CALLER_NOT_AUTHORIZED` | 403 | Authenticated but lacks required role | Missing app role for endpoint |
| `AGENT_IDENTITY_MISMATCH` | 403 | externalAgentId does not match authenticated identity | Data-plane identity binding failure |
| `AGENT_DISABLED` | 403 | Agent is in Disabled status | Data-plane request to disabled agent |
| `AGENT_NOT_FOUND` | 404 | Agent does not exist | Invalid agentId |
| `OPERATION_NOT_FOUND` | 404 | Operation does not exist | Invalid operationId |
| `DUPLICATE_EXTERNAL_AGENT_ID` | 409 | externalAgentId already registered | POST /agents with existing ID |
| `IDEMPOTENCY_CONFLICT` | 409 | Same Idempotency-Key, different body | Mismatched request body for key |
| `CONCURRENCY_CONFLICT` | 409 | ETag/rowVersion mismatch | Stale If-Match header |
| `INVALID_STATE_TRANSITION` | 409 | Operation not valid for current agent status | e.g., enable an already-active agent, retry non-failed |
| `PROVISIONING_FAILED` | 422 | Provisioning step failed | Unrecoverable provisioning error |
| `UNSUPPORTED_FEATURE_CONFIGURATION` | 422 | Requested feature combo not supported | e.g., Agent365 observability without prerequisites |
| `PURVIEW_POLICY_BLOCKED` | 403 | Content blocked by Purview DLP policy | processContent returned restrictAccess/block |
| `PURVIEW_DEPENDENCY_UNAVAILABLE` | 503 | Purview API unavailable (Enforce mode) | Timeout or error from Purview API in Enforce mode |
| `AGENT365_DEPENDENCY_UNAVAILABLE` | 503 | Agent 365 dependency unavailable | Timeout from Graph API during provisioning |
| `RATE_LIMIT_EXCEEDED` | 429 | Rate limit exceeded | Per-client or per-agent rate limit |
| `PAYLOAD_TOO_LARGE` | 413 | Request body exceeds maximum size | > 1 MB for batch, > 64 KB for single |
| `SERVICE_UNAVAILABLE` | 503 | Gateway temporarily unable to process | Database or critical dependency down |

### Validation Error Extension

For `VALIDATION_FAILED`, include a `validationErrors` array:

```json
{
  "type": "https://gateway.example.com/problems/validation-failed",
  "title": "One or more validation errors occurred.",
  "status": 400,
  "code": "VALIDATION_FAILED",
  "traceId": "00-example",
  "validationErrors": [
    {
      "field": "externalAgentId",
      "code": "REQUIRED",
      "detail": "externalAgentId is required."
    },
    {
      "field": "features.purviewMode",
      "code": "REQUIRED_WHEN",
      "detail": "purviewMode is required when purviewEnabled is true."
    }
  ]
}
```

---

## 5. Idempotency Semantics

### 5.1 Idempotency-Key Header

| Aspect | Rule |
|---|---|
| **Format** | UUID v4 (`Idempotency-Key: 550e8400-e29b-41d4-a716-446655440000`) |
| **Required on** | All data-plane mutating endpoints, enable/disable/delete/retry/reconcile |
| **Optional on** | `POST /agents` (registration uses `externalAgentId` uniqueness instead) |
| **Storage** | `IdempotencyRecord` table: key, request body hash, response, created timestamp |
| **TTL** | 7 days (configurable via system config) |
| **Same key + same body** | Return cached response with same status code |
| **Same key + different body** | Return `409 IDEMPOTENCY_CONFLICT` |
| **Missing key (required endpoint)** | Return `400 VALIDATION_FAILED` |

### 5.2 Implementation

1. Before processing, hash the request body (SHA-256).
2. Look up `IdempotencyRecord` by key.
3. If found and body hash matches → return stored response.
4. If found and body hash differs → return 409.
5. If not found → process the request. Store key + hash + response in the same transaction as the domain write.

---

## 6. Concurrency Semantics

### 6.1 Optimistic Concurrency (ETag / If-Match)

Used on: `PATCH /agents/{agentId}/features`, `PATCH /system/config`, `DELETE /agents/{agentId}`

| Aspect | Rule |
|---|---|
| **ETag format** | Base64-encoded SQL `rowVersion` value |
| **Required header** | `If-Match: "{etag}"` |
| **Missing If-Match** | Return `428 Precondition Required` |
| **Stale ETag** | Return `409 CONCURRENCY_CONFLICT` (or `412 Precondition Failed`) |
| **Implementation** | EF Core `[Timestamp]` / `rowVersion` column. `DbUpdateConcurrencyException` → 409. |

---

## 7. Rate Limiting

### 7.1 Strategy

Token bucket algorithm with configurable limits per scope:

| Scope | Default Limit | Header |
|---|---|---|
| Per-client (by `appid`/`azp`) | 600 requests/minute | `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset` |
| Per-agent (by `externalAgentId`) | 300 requests/minute | Same headers |
| Global | 10,000 requests/minute | — |

### 7.2 Rate Limit Response

`429 Too Many Requests`

```json
{
  "type": "https://gateway.example.com/problems/rate-limit-exceeded",
  "title": "Rate limit exceeded.",
  "status": 429,
  "code": "RATE_LIMIT_EXCEEDED",
  "detail": "Client has exceeded the allowed request rate. Retry after the specified time.",
  "traceId": "00-example"
}
```

**Headers:**
- `Retry-After: 5` (seconds)
- `X-RateLimit-Limit: 600`
- `X-RateLimit-Remaining: 0`
- `X-RateLimit-Reset: 1692763205`

---

## 8. Cursor-Based Pagination

### 8.1 Cursor Encoding

- Cursors are opaque Base64-encoded JSON: `{"id":"3d62b161-...","ts":"2026-08-23T04:30:00Z"}`
- Clients must not parse or construct cursors — they are opaque tokens.
- Cursors encode the sort key (default: `createdAtUtc` descending, then `id`).

### 8.2 Pagination Parameters

| Parameter | Type | Default | Max |
|---|---|---|---|
| `limit` | integer | 25 | 100 |
| `cursor` | string | null (first page) | — |

### 8.3 Response Shape

```json
{
  "items": [...],
  "nextCursor": "eyJpZCI6Ii4uLiIsInRzIjoiLi4uIn0=",
  "totalCount": 42
}
```

- `nextCursor` is `null` on the last page.
- `totalCount` is optional and may be omitted on large collections for performance. Included on agent lists where the total is useful for UI display.

---

## 9. Common Headers

### 9.1 Request Headers

| Header | Required | Description |
|---|---|---|
| `Authorization` | Yes (except health) | `Bearer {token}` |
| `Content-Type` | Yes (for bodies) | `application/json` |
| `Idempotency-Key` | Conditional | UUID v4, required on mutating data-plane + state change endpoints |
| `If-Match` | Conditional | ETag for optimistic concurrency |
| `X-Correlation-ID` | No | Client-provided correlation ID. Gateway generates one if absent. |
| `Accept` | No | `application/json` (default) |

### 9.2 Response Headers

| Header | Description |
|---|---|
| `Content-Type` | `application/json` or `application/problem+json` |
| `Location` | Resource URL on 201/202 |
| `Operation-Location` | Operation URL on async 202 |
| `ETag` | Row version for concurrency-controlled resources |
| `X-Correlation-ID` | Correlation ID (client-provided or gateway-generated) |
| `X-RateLimit-Limit` | Rate limit ceiling |
| `X-RateLimit-Remaining` | Remaining requests in window |
| `X-RateLimit-Reset` | Unix timestamp when window resets |
| `Retry-After` | Seconds to wait on 429 |

---

## Phase 3 Completion Checklist

- [x] Complete endpoint catalog (20 endpoints — 16 control-plane, 4 data-plane)
- [x] Authentication and authorization rules (2 security schemes, full authorization matrix, identity binding)
- [x] Request/response schemas with examples (all 20 endpoints)
- [x] Error model (RFC 9457 Problem Details, 18 stable error codes, validation error extension)
- [x] Idempotency semantics (Idempotency-Key behavior, TTL, conflict handling)
- [x] Concurrency semantics (ETag/If-Match, optimistic concurrency)
- [x] Rate limiting (token bucket, 3 scopes, response format)
- [x] Cursor-based pagination (opaque cursors, parameters, response shape)
- [x] Common headers (request and response)

## Open Issues for Phase 4

1. **Entity relationships:** Map the API schemas to EF Core entities — which fields are stored, which are computed.
2. **Index strategy:** Determine optimal indexes for cursor-based pagination, search, and filtering.
3. **Retention policy implementation:** How to enforce configurable retention for activity receipts, audit events, idempotency records.
4. **Soft-delete behavior:** Which entities use soft-delete vs hard-delete.

## Microsoft Documentation Citations

API design follows established Microsoft REST API guidelines:
- Problem Details (RFC 9457): https://learn.microsoft.com/aspnet/core/web-api/handle-errors
- ASP.NET Core OpenAPI: https://learn.microsoft.com/aspnet/core/fundamentals/openapi/overview
- Rate limiting middleware: https://learn.microsoft.com/aspnet/core/performance/rate-limit
- Microsoft Identity Web API protection: https://learn.microsoft.com/entra/msidweb/getting-started/quickstart-webapi

All Microsoft Graph API interactions validated in Phase 1 documentation matrix (`docs/architecture/doc-validation-matrix.md`).

## Decisions Needed Before Phase 4

1. **Soft-delete scope:** Which entities use soft-delete? All business records (spec suggests this) or only agent registrations?
2. **Activity receipt content:** Store full prompt/response in the database? The spec says minimize — likely store only metadata and receipt status, not content.
3. **Audit event immutability:** Should audit events be append-only with no update/delete? (Recommended: yes.)
