# Phase 3: API Contract

## Current implementation checkpoint

As of 2026-08-28, current source implements workflow v3: five worker stages, a
signed-in Gateway Administrator Registry action through API OBO, then final worker
connection verification. Development runs the documented continuous mode; staging
and production retain exact-bound admission windows. The broad Release gate passes
1,102/1,102 tests and the solution build has zero warnings/errors.

Two development registrations are Active: one created a new reusable blueprint and
one reused an existing blueprint. Both are visible as Available A365CustomGateway
agents in Microsoft 365 Admin Center. Bound data-plane requests returned HTTP 202,
the Agent 365 OTLP endpoint accepted sanitized exports, and the workflow-v3 queue
drained to zero active/scheduled messages. Blueprint-scoped Purview Enforce is also
live-proven: benign content is accepted as `AuditLogged`; a synthetic sensitive
`uploadText` is returned as `Blocked` without observability enqueue. The adapter
honors the policy's per-activity modes (`evaluateInline` or `evaluateOffline`) and
fails closed for missing or unknown modes. Historical ambiguous v2/v3 operations
remain preserved and must not be replayed or attached. SQL finalization is
unapplied. Exact live revisions, safe identifiers, authorization, and the resume
point belong in
[`development-deployment-status.md`](../operations/development-deployment-status.md)
and [`implementation-status.md`](../implementation-status.md), not in this contract.

## 1. Endpoint Catalog

All endpoints are **gateway-owned APIs designed for this solution, not Microsoft APIs.**

The catalog follows the currently implemented controllers plus one explicitly
planned reconciliation operation. The OpenAPI document contains only exposed
operations; do not infer a route from the planned row.

Base path: `/api/v1`

Content type: `application/json`

Timestamps: UTC ISO 8601

Identifiers: UUID (gateway-generated), string (external agent IDs)

### 1.1 Control-Plane Endpoints

| # | Method | Path | Description | Auth Roles | Idempotency | Concurrency |
|---|---|---|---|---|---|---|
| 1 | `POST` | `/agents` | Register a new external agent | `Gateway.Administrator` | — | Unique `externalAgentId` constraint |
| 1a | `GET` | `/agent-identity-blueprints` | List typed reusable Agent ID blueprints for registration | `Gateway.Administrator` | — | — |
| 2 | `GET` | `/agents` | List agents (filtered, paged) | `Gateway.Administrator`, `Gateway.Operator`, `Gateway.Auditor`, `Gateway.SupportReader` | — | — |
| 3 | `GET` | `/agents/{agentId}` | Get agent details | `Gateway.Administrator`, `Gateway.Operator`, `Gateway.Auditor`, `Gateway.SupportReader` | — | — |
| 3a | `GET` | `/agents/{agentId}/credentials` | List safe Gateway credential metadata | `Gateway.Administrator` | — | — |
| 3b | `POST` | `/agents/{agentId}/credentials` | Issue a replacement Gateway credential; clear key returned once | `Gateway.Administrator` | — | Transactional issue + audit |
| 3c | `DELETE` | `/agents/{agentId}/credentials/{credentialId}` | Revoke a named Gateway credential | `Gateway.Administrator` | Idempotent once owned/revoked | Refuses last usable key |
| 4 | `PATCH` | `/agents/{agentId}/features` | Update feature configuration | `Gateway.Administrator` | — | `If-Match` (ETag/rowVersion) |
| 5 | `POST` | `/agents/{agentId}:enable` | Enable an agent | `Gateway.Administrator`, `Gateway.Operator` | `Idempotency-Key` | — |
| 6 | `POST` | `/agents/{agentId}:disable` | Disable an agent | `Gateway.Administrator`, `Gateway.Operator` | `Idempotency-Key` | — |
| 7 | `DELETE` | `/agents/{agentId}` | Delete an agent (async) | `Gateway.Administrator` | `Idempotency-Key` | `If-Match` (ETag/rowVersion) |
| 8 | `POST` | `/agents/{agentId}:retry-provisioning` | Retry failed provisioning | `Gateway.Administrator` | `Idempotency-Key` | — |
| 9 | `POST` | `/agents/{agentId}:reconcile` | **Planned, not exposed by the current API.** Target contract for on-demand reconciliation | `Gateway.Administrator` | `Idempotency-Key` | — |
| 10 | `GET` | `/operations/{operationId}` | Get operation status | `Gateway.Administrator`, `Gateway.Operator` | — | — |
| 10a | `POST` | `/operations/{operationId}:complete-agent365-registration` | Complete the workflow-v3 Registry stage through delegated OBO | Authenticated `Gateway.Administrator` user with valid `oid` and `access_as_user`; app-only rejected | Durable planned attempt + at most one POST; HTTP 201 plus the safe returned/fallback ID is the accepted create boundary | Per-job SQL lock |
| 11 | `GET` | `/agents/{agentId}/audit-events` | Get agent audit history | `Gateway.Administrator`, `Gateway.Auditor` | — | — |
| 12 | `GET` | `/agents/{agentId}/provisioning-history` | Get provisioning job history | `Gateway.Administrator`, `Gateway.Operator` | — | — |
| 13 | `GET` | `/system/config` | Get system configuration | `Gateway.Administrator` | — | — |
| 14 | `PATCH` | `/system/config` | Update system configuration | `Gateway.Administrator` | — | `If-Match` |
| 15 | `GET` | `/health` | Health check (liveness) | Anonymous | — | — |
| 16 | `GET` | `/health/ready` | Readiness check | Anonymous | — | — |

### 1.2 Data-Plane Endpoints

| # | Method | Path | Description | Auth Roles | Idempotency | Concurrency |
|---|---|---|---|---|---|---|
| 17 | `POST` | `/agent-activities` | Submit a single activity | Registration-bound Gateway API key | `Idempotency-Key` (required) | — |
| 18 | `POST` | `/agent-activities:batch` | Submit a batch of activities | Registration-bound Gateway API key | `Idempotency-Key` (required) | — |
| 19 | `POST` | `/ai-interactions` | Submit a completed AI interaction; optional Purview work is synchronous | Registration-bound Gateway API key | `Idempotency-Key` (required) | — |
| 20 | `GET` | `/agent-runtime/readiness` | Verify a registration-bound Gateway API key | Registration-bound Gateway API key | — | — |

---

## 2. Authentication and Authorization Rules

### 2.1 Security Schemes

| Scheme | Type | Description | Used By |
|---|---|---|---|
| `EntraInteractive` | OpenID Connect (auth code flow) | Admin users sign in via Entra ID. ID token + access token with delegated scopes. | AdminUI → API |
| `GatewayAgentApiKey` | HTTP Bearer with Gateway-issued opaque key | Unique per registration; clear key returned once, salted hash stored. Resolves the caller to one registration. | External agents → API |

### 2.2 Token Validation

Control-plane requests require an Entra Bearer token validated by Microsoft Identity
Web. Data-plane/readiness requests require the `GatewayAgentApiKey` scheme. The two
Bearer formats are intentionally resolved by endpoint policy, not accepted
interchangeably.

| Check | Detail |
|---|---|
| Signature | RS256, validated against Entra ID OIDC metadata keys |
| Issuer | `https://login.microsoftonline.com/{tenantId}/v2.0` or v1.0 equivalent |
| Audience | Gateway API application ID |
| Expiry | `exp` claim must be in the future |
| Roles | `roles` claim must contain one of the required roles for the endpoint |

For a Gateway agent key, validation parses the key ID, loads that credential, rejects
expired/revoked/deleted registrations, hashes the presented high-entropy secret with
the persisted salt, compares in fixed time, and issues only registration-scoped
claims. The clear key never appears in SQL, logs, audit events, or later reads.

### 2.3 Per-Endpoint Authorization Matrix

| Endpoint | Gateway.Administrator | Gateway.Operator | Gateway.Auditor | Gateway.SupportReader | Gateway agent key |
|---|---|---|---|---|---|
| `POST /agents` | Yes | — | — | — | — |
| `GET /agent-identity-blueprints` | Yes | — | — | — | — |
| `GET /agents` | Yes | Yes | Yes | Yes (redacted) | — |
| `GET /agents/{agentId}` | Yes | Yes | Yes | Yes (redacted) | — |
| `GET /agents/{agentId}/credentials` | Yes | — | — | — | — |
| `POST /agents/{agentId}/credentials` | Yes | — | — | — | — |
| `DELETE /agents/{agentId}/credentials/{credentialId}` | Yes | — | — | — | — |
| `PATCH /agents/{agentId}/features` | Yes | — | — | — | — |
| `POST /agents/{agentId}:enable` | Yes | Yes | — | — | — |
| `POST /agents/{agentId}:disable` | Yes | Yes | — | — | — |
| `DELETE /agents/{agentId}` | Yes | — | — | — | — |
| `POST /agents/{agentId}:retry-provisioning` | Yes | — | — | — | — |
| `POST /agents/{agentId}:reconcile` | Yes | — | — | — | — |
| `GET /operations/{operationId}` | Yes | Yes | — | — | — |
| `POST /operations/{operationId}:complete-agent365-registration` | Yes, user token only | — | — | — | — |
| `GET /agents/{agentId}/audit-events` | Yes | — | Yes | — | — |
| `GET /agents/{agentId}/provisioning-history` | Yes | Yes | — | — | — |
| `GET /system/config` | Yes | — | — | — | — |
| `PATCH /system/config` | Yes | — | — | — | — |
| `POST /agent-activities` | — | — | — | — | Yes |
| `POST /agent-activities:batch` | — | — | — | — | Yes |
| `POST /ai-interactions` | — | — | — | — | Yes |
| `GET /agent-runtime/readiness` | — | — | — | — | Yes |

### 2.4 Data-Plane Identity Binding

For data-plane activity and interaction endpoints that carry an `externalAgentId`,
the Gateway enforces agent-to-registration binding:

1. Validate the per-registration Gateway API key and resolve its credential ID to
   one `AgentRegistrationId`. This caller-registration resolution happens before any
   routing decision based on request content.
2. Load that registration and reject expired/revoked credentials or deleted agents.
3. Compare `externalAgentId` from the request body against the authenticated registration.
4. If mismatch → `403 AGENT_IDENTITY_MISMATCH`.
5. If agent status ≠ `Active` → `403 AGENT_DISABLED` (or appropriate error).

The registration request supplies no external-runtime identity. Provisioning still
stores the child Agent ID/client ID for outbound Agent 365 attribution, but that ID
is not Gateway ingress authentication. Gateway credential ID, registration ID,
blueprint IDs, and child Agent ID are not interchangeable.
Microsoft currently documents the child Agent Identity object ID and app/client ID
as the same GUID; the Gateway retains explicit field names and verifies equality.
A typed blueprint likewise returns separately named Graph `id` and `appId` fields,
but their values may be the same GUID. Clients and the Gateway must preserve the
field semantics without enforcing equality or inequality.

### 2.5 SupportReader Redaction

When `Gateway.SupportReader` accesses agent data, the following fields are redacted:

- `ownerObjectId` → `"[REDACTED]"`
- `externalClientId` → `"[REDACTED]"`
- `agent365AgentId` → last 4 characters only
- `blueprintId` → last 4 characters only
- Audit event details containing user identifiers → redacted

---

## 3. Request/Response Schemas

### Observability destination compatibility

Agent telemetry destinations are configured independently. New clients should use the
boolean destination fields; the string mode fields remain only for backward
compatibility.

| Agent field | System-default field | Default | Effect |
|---|---|---|---|
| `agent365ObservabilityEnabled` | `defaultAgent365ObservabilityEnabled` | `true` | Sends sanitized agent metrics and traces to Agent 365 observability. |
| `azureMonitorExportEnabled` | `defaultAzureMonitorExportEnabled` | `false` | Optionally mirrors the same sanitized agent telemetry to Azure Monitor / Application Insights. |

The deprecated compatibility values map to the independent destinations as follows:

| Deprecated `observabilityMode` value | Agent 365 | Azure Monitor mirror |
|---|---:|---:|
| `Disabled` | Off | Off |
| `GatewayOnly` | Off | On |
| `Agent365` | On | Off |
| `Agent365AzureMonitor` | On | On |

When both the deprecated mode and one or more destination booleans are supplied, they
must describe the same combination; an ambiguous or conflicting request is rejected.
Gateway/platform diagnostics are emitted independently of these per-agent settings.
Microsoft Purview enablement and mode are also separate controls.
Deployment prerequisites and the live-default rollout step are documented in the
[Agent 365 observability setup runbook](../operations/agent365-observability-setup.md).

For Agent 365 export, the Gateway maps the registration's child Agent Identity
client ID to `gen_ai.agent.id` and the selected blueprint client ID to
`microsoft.a365.agent.blueprint.id`. It omits `gen_ai.agent.type` and
`microsoft.a365.agent.platform.id` for this Entra child identity model. These
attributes are produced by the Gateway and are not caller-overridable routing
fields. An OTLP HTTP 200 proves endpoint acceptance only; it does not prove that the
event has landed in Defender `CloudAppEvents`. The controlled live canary must verify
that downstream evidence separately after the expected delay and licensing path.

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
    "agent365ObservabilityEnabled": true,
    "azureMonitorExportEnabled": false,
    "purviewEnabled": true,
    "purviewMode": "Enforce"
  },
  "blueprint": {
    "mode": "UseExisting",
    "blueprintObjectId": "11111111-1111-1111-1111-111111111111",
    "displayName": null
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
| `features.agent365ObservabilityEnabled` | boolean | No | Default: system setting, initially `true` |
| `features.azureMonitorExportEnabled` | boolean | No | Default: system setting, initially `false` |
| `features.observabilityMode` | enum | No | **Deprecated compatibility field.** `Disabled`, `GatewayOnly`, `Agent365`, or `Agent365AzureMonitor` |
| `features.purviewEnabled` | boolean | No | Default: `false` |
| `features.purviewMode` | enum | No | `AuditOnly` or `Enforce`; defaults to the system mode, or `AuditOnly` when Purview is enabled without a configured mode |
| `blueprint` | object | Yes | Reusable Agent ID blueprint selection; Gateway federation is trusted service configuration |
| `blueprint.mode` | enum | Yes | `UseExisting` or `CreateNew` |
| `blueprint.blueprintObjectId` | string (UUID) | Conditional | Required only for `UseExisting`; use the catalog item's typed blueprint Graph `id`. Its value may equal that item's `appId`; do not substitute an ordinary app ID. |
| `blueprint.displayName` | string | Conditional | Required only for `CreateNew`; 1-256 chars; names a reusable blueprint |

**Response:** `202 Accepted`

```json
{
  "agentId": "3d62b161-e342-4cc5-bd3e-e98fa91431df",
  "externalAgentId": "crm-assistant-prod",
  "name": "CRM Assistant",
  "status": "Provisioning",
  "operationId": "31395296-1962-4ed4-963c-d1546dd274b1",
  "createdAtUtc": "2026-08-23T04:30:00Z",
  "gatewayCredential": {
    "keyId": "48e6107a-a1d0-4bc7-a76a-df9b18c797d0",
    "apiKey": "<one-time Gateway agent API key>",
    "expiresAtUtc": "2027-08-23T04:30:00Z"
  },
  "_links": {
    "self": "/api/v1/agents/3d62b161-e342-4cc5-bd3e-e98fa91431df",
    "operation": "/api/v1/operations/31395296-1962-4ed4-963c-d1546dd274b1"
  }
}
```

**Headers:**
- `Location: /api/v1/agents/{agentId}`
- `Operation-Location: /api/v1/operations/{operationId}`

Registration is deployment-gated. The effective
`GET /api/v1/system/config.provisioningExecutionEnabled` value is true only when the
boolean execution setting is enabled **and** `AdmissionExpiresAtUtc` is a parseable
future UTC instant. In the current exact-bound mode,
`RequireExactAdmissionBinding=true` also requires a nonempty
`AuthorizedExternalAgentId`, and the create request must match it exactly. Retry is
independently bound by `AuthorizedRetryAgentId`. Otherwise the API returns RFC 9457
`503 PROVISIONING_DISABLED` **before** creating an agent, provisioning job, or
outbox message. Authenticated system config returns the authorized create value as
nullable `authorizedRegistrationExternalAgentId` so the Admin UI can submit the
server-authorized generated ID. It is public admission/routing metadata, not a
credential. These effective fields are read-only deployment capabilities; they are
not editable through `PATCH /system/config`.

The development controller allows 60--300 seconds for revision rollout (default
300), starts its 30--300 second operator window (default 120) only after the open
revision is ready, and sets an API-enforced hard deadline no more than 600 seconds
after the update request. In exact-binding mode the API also accepts only the one
configured `Provisioning__AuthorizedExternalAgentId`; retry has its own independent
agent-ID binding and remains unset for the initial canary.

`gatewayCredential.apiKey` is returned only in this issuance response. The Gateway
stores only its salted hash and lifecycle metadata. The caller must move the clear
value directly into the external agent's secret manager; it must not be written to a
URL, log, audit event, SQL row, runbook, or browser storage. The key authenticates
only the returned registration, and request `externalAgentId` is still cross-checked.
If the caller does not receive or loses this successful one-time response, the
Gateway cannot replay or recover the clear value and the response is deliberately
absent from idempotency storage. Treat the result as outcome-known only after reading
the registration/credential metadata; issue a replacement through the administrator
credential endpoint and deploy/verify it before revoking any usable key. Never retry
registration merely to obtain another copy of the original secret.

This blueprint-aware N:N request creates workflow version 3. Development runs the
isolated workflow-v3 deployment, while workflow v2 remains retained only as immutable
historical evidence on its separate queue. Creation remains intentionally closed
outside its exact-bound controller window. An ordinary Entra app registration or the
Gateway API application cannot be supplied as a blueprint. `CreateNew` creates one
reusable blueprint; each registration still gets a distinct child Agent Identity.

Internally, this Gateway-owned request is implemented with Microsoft Graph's typed
Agent ID routes: Blueprint collection/object and Blueprint Principal reads retain
their `microsoft.graph.agentIdentityBlueprint*` casts, and Agent Identity
verification calls
`GET /v1.0/servicePrincipals/{id}/microsoft.graph.agentIdentity` with
`$expand=sponsors($select=id)`. Sponsor validation therefore does not depend on a
base service-principal projection. These Microsoft routes are implementation
dependencies, not additional Gateway API endpoints.

### 3.1a List Agent Identity Blueprints

**Request:** `GET /api/v1/agent-identity-blueprints`

**Authorization:** `Gateway.Administrator`

```json
{
  "items": [
    {
      "blueprintObjectId": "11111111-1111-1111-1111-111111111111",
      "blueprintClientId": "11111111-1111-1111-1111-111111111111",
      "displayName": "Reusable customer-service blueprint",
      "isAgent365Compatible": true,
      "agent365CompatibilityIssue": null
    }
  ]
}
```

This is a Gateway-owned catalog backed by the typed Microsoft Graph list method. It
validates every page/identifier and fails closed on malformed, hostile, repeated, or
unavailable paging results; a dependency failure is never returned as an empty
inventory. `blueprintObjectId` and `blueprintClientId` preserve Graph `id` and
`appId` semantics; the values may be equal, as they were for all 11 entries in an
earlier 2026-08-25 development inventory. The later live compatibility catalog has
12 rows, so the historical equality observation does not assert anything about the
added row. Every typed blueprint remains visible, but
`isAgent365Compatible` is true only when it contains every manager application
required by this Gateway deployment. An incompatible row reports the safe issue
`MissingRequiredManagerApplications` (or `ManagerApplicationsNotConfigured` when
the Gateway configuration is absent), never the manager application IDs themselves.
The registration API rechecks the current catalog and rejects an incompatible or
stale existing-blueprint selection before it persists a registration or issues a
Gateway key. The API managed identity requires the Graph application role
`AgentIdentityBlueprint.Read.All`. A signed-in Global Administrator is authorized to
call the Gateway route but does not lend its Graph privileges to the API identity.

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
        "agent365ObservabilityEnabled": true,
        "azureMonitorExportEnabled": false,
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
    "agentId": "c20cd860-4cbe-4478-9ca6-0f8ed81f1980",
    "blueprintId": "3a5d3fb4-6c4b-4ffc-bbb7-3e0fae86dad5",
    "instanceId": "registry-preview-record-id",
    "agentIdentityObjectId": "5455bb87-a410-4ea4-a68a-84f654387a34",
    "blueprintObjectId": "ad4d5de8-5a49-4fad-9fea-428f74d3876d"
  },
  "features": {
    "observabilityMode": "Agent365",
    "agent365ObservabilityEnabled": true,
    "azureMonitorExportEnabled": false,
    "purviewEnabled": true,
    "purviewMode": "Enforce"
  },
  "provisioningStatus": {
    "currentStep": "Completed",
    "percentComplete": 100,
    "lastError": null
  },
  "retryProvisioning": {
    "supported": false,
    "reason": "Retry is available only after the Gateway confirms a safely retryable provisioning failure."
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

`retryProvisioning` is the authoritative server-computed retry-safety decision.
Clients must fail closed when it is absent or `supported` is false; `status ==
"Failed"` alone does not make a provisioning operation safe to replay. The `reason`
is an operator-safe summary and never contains raw provider response text.

**Headers:**
- `ETag: "AAAAAAAAB9E="`

### 3.3a Manage Gateway Agent Credentials

All three routes are `Gateway.Administrator` only. List responses expose only safe
metadata—never the clear key, hash, or salt.

**List:** `GET /api/v1/agents/{agentId}/credentials`

```json
{
  "agentId": "3d62b161-e342-4cc5-bd3e-e98fa91431df",
  "items": [
    {
      "keyId": "48e6107a-a1d0-4bc7-a76a-df9b18c797d0",
      "createdAtUtc": "2026-08-25T03:00:00Z",
      "expiresAtUtc": "2027-08-25T03:00:00Z",
      "revokedAtUtc": null
    }
  ]
}
```

**Issue replacement:** `POST /api/v1/agents/{agentId}/credentials`

Returns `201 Created` with `externalAgentId` and the same one-time
`gatewayCredential` shape returned by registration. It sets `Cache-Control: no-store`
and `Pragma: no-cache`. The clear key must be deployed to the external agent and
verified before the old key is revoked.
If the clear response is lost, do not ask the Gateway to replay it and do not search
SQL, audit, logs, or idempotency rows. List safe metadata, issue another replacement,
then deploy/verify that new key before any revocation.

**Revoke named credential:**
`DELETE /api/v1/agents/{agentId}/credentials/{credentialId}`

Returns `200 OK` with safe revocation metadata. Revoking an already revoked owned key
is idempotent. A credential not owned by the route agent returns
`404 AGENT_INGRESS_CREDENTIAL_NOT_FOUND`. Revoking the last unexpired, unrevoked key
returns `409 AGENT_INGRESS_CREDENTIAL_LAST_USABLE`; issue, deploy, and verify a
replacement first.

Issue/revoke and their safe `GatewayCredentialIssued`/
`GatewayCredentialRevoked` audit events commit through one unit of work. Audit data
contains only credential ID and timestamps.

### 3.4 Update Feature Configuration

**Request:** `PATCH /api/v1/agents/{agentId}/features`

**Headers:** `If-Match: "AAAAAAAAB9E="`

```json
{
  "agent365ObservabilityEnabled": true,
  "azureMonitorExportEnabled": true,
  "purviewEnabled": false
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `agent365ObservabilityEnabled` | boolean | No | Enables or disables Agent 365 export without changing the Azure Monitor mirror setting |
| `azureMonitorExportEnabled` | boolean | No | Enables or disables the optional Azure Monitor mirror without changing Agent 365 export |
| `observabilityMode` | enum | No | **Deprecated compatibility field.** `Disabled`, `GatewayOnly`, `Agent365`, or `Agent365AzureMonitor` |
| `purviewEnabled` | boolean | No | |
| `purviewMode` | enum | No | Required if `purviewEnabled` is being set to `true` |

**Response:** `200 OK`

```json
{
  "agentId": "3d62b161-e342-4cc5-bd3e-e98fa91431df",
  "features": {
    "observabilityMode": "Agent365AzureMonitor",
    "agent365ObservabilityEnabled": true,
    "azureMonitorExportEnabled": true,
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

Current behavior is intentionally asymmetric: with
`deleteMicrosoftResources=false`, the worker can complete Gateway-only deletion
while preserving Microsoft resources. With `deleteMicrosoftResources=true`, the
Microsoft deletion adapter is unsupported and the job transitions to
`RequiresManualIntervention`/DLQ. It never reports external resources as deleted.

### 3.8 Retry Provisioning

**Request:** `POST /api/v1/agents/{agentId}:retry-provisioning`

**Headers:** `Idempotency-Key: 550e8400-e29b-41d4-a716-446655440003`

Precondition: `Failed` status is necessary but not sufficient. The latest agent
representation must report `retryProvisioning.supported == true`, and the endpoint
re-evaluates that server-computed decision before persisting a new job. Clients must
fail closed when the decision is absent or false. Legacy workflow jobs,
manual-intervention outcomes, an already active operation, and ambiguous or
in-flight beta Registry creates are not replayable. An unsafe or stale retry request
returns `409`; clients must not infer safety from status alone.

The same deployment gate as registration applies. When provisioning execution is
disabled, the API returns `503 PROVISIONING_DISABLED` before creating a retry job
or outbox message.

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

**Target contract only.** The current API does not expose this route and the current
Microsoft reconciliation adapter is fail-closed unsupported. Any legacy/internal
reconciliation message transitions to manual intervention rather than reporting the
agent as in sync. Do not build UI or automation that calls this route until both the
controller and a verified adapter are implemented.

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

This endpoint reports persisted Gateway job state. The example below is the
intentional workflow-v3 Administrator boundary; it is not independent proof of a
Microsoft resource. A step is `Completed` only after its current owner persists the
required safe verification evidence. Every v1/v2 job is legacy/non-resumable under
v3.

```json
{
  "operationId": "31395296-1962-4ed4-963c-d1546dd274b1",
  "type": "ProvisionAgent",
  "status": "AwaitingAdministratorAction",
  "currentStep": "RegisterAgent",
  "percentComplete": 71,
  "agentId": "3d62b161-e342-4cc5-bd3e-e98fa91431df",
  "startedAtUtc": "2026-08-23T04:30:01Z",
  "completedAtUtc": null,
  "error": null,
  "workflowVersion": 3,
  "legacy": false,
  "replaySupported": false,
  "pollingRecommended": false,
  "requiredAction": "CompleteAgent365Registration",
  "steps": [
    { "step": "ResolveBlueprint", "status": "Completed", "completedAtUtc": "2026-08-23T04:30:05Z" },
    { "step": "EnsureBlueprintPrincipal", "status": "Completed", "completedAtUtc": "2026-08-23T04:30:08Z" },
    { "step": "ConfigureGatewayFederation", "status": "Completed", "completedAtUtc": "2026-08-23T04:30:12Z" },
    { "step": "CreateAgentIdentity", "status": "Completed", "completedAtUtc": "2026-08-23T04:30:18Z" },
    { "step": "AssignAgent365Access", "status": "Completed", "completedAtUtc": "2026-08-23T04:30:24Z" },
    { "step": "RegisterAgent", "status": "Pending", "completedAtUtc": null },
    { "step": "VerifyAgent365Connection", "status": "Pending", "completedAtUtc": null }
  ]
}
```

- `workflowVersion` is `3` only for the exact current sequence.
- `legacy=true` means the recorded version/shape is not current. Legacy operations
  are not resumable, must not be replayed into v3, and should not be continuously
  polled as though they can advance.
- `requiredAction=CompleteAgent365Registration` appears only for the exact v3
  five-step prefix with Register pending/running and final verify pending.
- `replaySupported` is false while Administrator action is required and never
  authorizes DLQ replay.
- `pollingRecommended` is false while waiting for the Administrator and becomes true
  after accepted Registry creation queues the final stage.
- `VerifyAgent365Connection` re-reads the blueprint, principal, Gateway FIC, child
  Agent ID, and Agent 365 role assignment, then validates the child token. It makes
  no Registry HTTP call and requires persisted delegated acceptance evidence.

**Operation types:** `ProvisionAgent`, `DeleteAgent`, `RetryProvisioning`; the enum
also contains planned/legacy `ReconcileAgent`, but no current API route starts it.

**Operation statuses:** `Pending`, `Running`, `Completed`, `Failed`,
`RequiresManualIntervention`, `AwaitingAdministratorAction`

### 3.10a Complete Agent 365 Registration

**Request:**

```http
POST /api/v1/operations/{operationId}:complete-agent365-registration
Authorization: Bearer <Gateway API user token>
```

No request body, Registry ID, token, assertion, or JSON upload is accepted. The
endpoint requires an authenticated `Gateway.Administrator` user with a valid Entra
`oid` and delegated `access_as_user`; app-only tokens and every other role are
rejected. Registration admission must already be closed. Delegated Registry execution
must be independently enabled, unexpired, and exact-bound to this `operationId`
through `RequireExactActionBinding`, `ActionExpiresAtUtc`, and
`AuthorizedOperationId`.

The API validates the exact v3 state under the per-job SQL lock, pre-acquires OBO
for `AgentRegistration.ReadWrite.All` plus `AgentRegistration.Read.All`, persists a
creator-bound attempt with a planned Registry ID, and emits at most one Registry
POST. The CLI-compatible create includes that `id` plus the reviewed preview-
provider `managedByAppId`; it uses the Gateway external ID as `sourceAgentId` and
the signed-in Administrator `oid` as `createdBy`. HTTP 201 persists the safe returned
ID immediately, using the planned ID only when a successful response omits one;
immediate exact GET is not required.

**Response:** `200 OK`

```json
{
  "operationId": "31395296-1962-4ed4-963c-d1546dd274b1",
  "agentId": "3d62b161-e342-4cc5-bd3e-e98fa91431df",
  "agent365RegistrationId": "0eb95153-25f5-49ac-9f56-a4f7b9d9fb9c",
  "status": "VerificationQueued"
}
```

Consent/Conditional Access failure before intent performs no create. Unknown POST
outcome permits exact planned-ID GET only; the POST is never repeated. A transient
read remains creator-bound and GET-only, while mismatch or nonrecoverable ambiguity
is manual. A returned HTTP 201 plus a safe durable ID is accepted without immediate
exact GET. Historical v1/v2 operations and unsafe prefixes are rejected before
Registry mutation.

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

**Current control-plane event strings:** `AgentRegistered`, `AgentEnabled`,
`AgentDisabled`, `AgentDeletionRequested`,
`GatewayRegistrationDeletedResourcesPreserved`,
`AgentDeletionRequiresManualIntervention`, `ProvisioningStepCompleted`,
`ProvisioningCompleted`, `ProvisioningFailed`, `ProvisioningRetried`,
`FeaturesUpdated`, `ReconciliationPassed`,
`ReconciliationRequiresManualIntervention`, and `SystemConfigUpdated`.

Event type is an extensible string, not a closed wire enum. The current fail-closed
reconciliation adapter cannot produce `ReconciliationPassed`, and the current
Microsoft-deletion adapter cannot produce `AgentResourcesDeleted`; those success
strings may exist in handler structure but are not current runtime claims. Clients
must tolerate new event strings and must not infer an external result from the name
without the corresponding verified operation state.

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
        { "step": "ResolveBlueprint", "status": "Completed" },
        { "step": "EnsureBlueprintPrincipal", "status": "Completed" },
        { "step": "ConfigureGatewayFederation", "status": "Completed" },
        { "step": "CreateAgentIdentity", "status": "Completed" },
        { "step": "AssignAgent365Access", "status": "Completed" },
        { "step": "RegisterAgent", "status": "Completed" },
        { "step": "VerifyAgent365Connection", "status": "Completed" }
      ],
      "error": null
    }
  ],
  "nextCursor": null
}
```

Provisioning-history items preserve their recorded step names but don't currently
expose the operation endpoint's `workflowVersion`/`legacy` flags. Clients must not
use a history row to authorize replay. Fetch the operation status: exact workflow
version 3 plus the seven current stages is necessary but not sufficient, because
`replaySupported=false` also covers manual-intervention outcomes, ambiguous Registry
mutations, and an in-flight Registry create. Every other version/shape is legacy.

### 3.13 System Configuration

**Request:** `GET /api/v1/system/config`

**Response:** `200 OK`

```json
{
  "provisioningMode": "Automatic",
  "defaultObservabilityMode": "Agent365",
  "defaultAgent365ObservabilityEnabled": true,
  "defaultAzureMonitorExportEnabled": false,
  "defaultPurviewEnabled": false,
  "defaultPurviewMode": null,
  "retentionDaysActivityReceipts": 90,
  "retentionDaysAuditEvents": 365,
  "retentionDaysIdempotencyRecords": 7,
  "retentionDaysOutboxMessages": 30,
  "rateLimitPerClient": 100,
  "rateLimitPerAgent": 1000,
  "rateLimitGlobal": 10000,
  "reconciliationEnabled": true,
  "reconciliationIntervalHours": 24,
  "stuckTransitionTimeoutDays": 7,
  "useGraphAgentRegistration": false,
  "useCliProvisioningFallback": false,
  "provisioningExecutionEnabled": false,
  "authorizedRegistrationExternalAgentId": null
}
```

`defaultAgent365ObservabilityEnabled` and
`defaultAzureMonitorExportEnabled` are the canonical defaults applied to new agent
registrations that omit destination settings. `defaultObservabilityMode` is a
deprecated compatibility field and follows the same four-value mapping shown above.
`PATCH /api/v1/system/config` accepts the two canonical fields independently; if the
deprecated field is also sent, all supplied values must agree.
`provisioningExecutionEnabled` is read-only and comes from deployment configuration;
it is returned by both GET and PATCH responses but is not accepted in the PATCH body.
`authorizedRegistrationExternalAgentId` is also read-only. It is non-null only while
an exact-bound registration window is effectively open, and lets the authenticated
Admin UI use the server-authorized generated external ID. It is not a Gateway key,
Microsoft credential, token, or permission to complete a different operation.
`useGraphAgentRegistration` and `useCliProvisioningFallback` are persisted deprecated
compatibility fields. They do not select the current provider, enable execution, or
create an unattended CLI fallback; deployment configuration and the preflight gates
are authoritative.
`reconciliationEnabled` and `reconciliationIntervalHours` are also persisted
compatibility values: the current Gateway has no verified reconciliation scheduler
or Microsoft-resource adapter, and the Admin UI does not edit them.

### 3.14 Agent Runtime Readiness

**Request:** `GET /api/v1/agent-runtime/readiness`

**Authorization:** the registration-bound Gateway agent API key.

**Response:** `204 No Content`

This Gateway-owned, non-mutating probe proves that the presented API key is valid,
unexpired, unrevoked, and bound to a non-deleted registration. It has no request or
response body and does not replace `/health`, `/health/ready`, or the outbound Agent
365 token proof. It intentionally does **not** require the registration to be
`Active`; `Draft`, `Provisioning`, `Disabled`, or `Failed` is not a key-validity
failure. Ingestion endpoints enforce their separate operational-state policy. The
workflow does not self-call this route.

**Errors:** `401` for an absent, malformed, expired, revoked, or invalid Gateway key;
`403` for a later registration policy rejection.

### 3.15 Submit Activity

**Request:** `POST /api/v1/agent-activities`

**Headers:**
- `Authorization: Bearer {gateway-agent-api-key}`
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
    "type": "User",
    "tenantUserObjectId": "00000000-0000-0000-0000-000000000045"
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
| `actor.type` | enum | Yes | `Agent`, `User`, `System`. Must be `User` when Agent 365 observability is enabled. `Agent` and `System` remain supported for `Disabled` and `GatewayOnly`. |
| `actor.tenantUserObjectId` | string (UUID) | Conditional | Microsoft Entra tenant user object ID. Required and non-empty with the supported `User` actor when Agent 365 observability is enabled; otherwise optional. |
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

When Agent 365 observability is enabled, `actor.type` must be `User`. Another actor
type, or a missing, empty, or invalid `actor.tenantUserObjectId`, returns RFC 9457
Problem Details with HTTP 400 and `VALIDATION_FAILED`; no activity receipt or outbox
message is created. The current contract cannot safely describe agent-to-agent (A2A)
attribution: Agent 365 requires caller-agent identity fields such as the caller app,
name, blueprint, and agent-user identity, which are not present here. Callers must
not mislabel an agent as a human user to bypass this validation.

### 3.16 Batch Activities

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
      "actor": {
        "type": "User",
        "tenantUserObjectId": "00000000-0000-0000-0000-000000000045"
      },
      "tool": { "name": "CustomerLookup", "operation": "Get", "outcome": "Succeeded", "durationMs": 218 }
    },
    {
      "activityId": "event-2",
      "sessionId": "session-12345",
      "activityType": "Chat",
      "occurredAtUtc": "2026-08-23T04:45:01Z",
      "actor": {
        "type": "Agent",
        "tenantUserObjectId": "00000000-0000-0000-0000-000000000045"
      }
    }
  ]
}
```

| Limit | Value |
|---|---|
| Max events per batch | 100 |
| Max request body size | 1 MB |
| Partial success | Supported — each item gets its own status |
| `actor.type` | Must be `User` for each item when Agent 365 observability is enabled; `Agent` and `System` remain supported when it is disabled |
| `actor.tenantUserObjectId` | Required and non-empty for each supported `User` item when Agent 365 observability is enabled; otherwise optional |

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
      "detail": "Actor.Type must be User when Agent 365 observability is enabled."
    }
  ],
  "correlationId": "0dccba49-df57-4274-9332-137799481b89"
}
```

When Agent 365 observability is enabled, each item whose `actor.type` is not `User`,
or whose `actor.tenantUserObjectId` is missing, empty, or malformed, is returned as
`Rejected` with `VALIDATION_FAILED`; valid sibling items continue to be accepted.
Actor/user-context validation does not turn the whole batch into an HTTP 400 response.
Supporting A2A export requires a future contract extension for Agent 365's dedicated
caller-agent identity fields.

### 3.17 Submit Completed AI Interaction

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
| `userContext.tenantUserObjectId` | string (UUID) | Conditional | Microsoft Entra tenant user object ID. Required and non-empty when Agent 365 observability is enabled and for Purview evaluation. |
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
  "purviewProcessing": "PurviewDisabled",
  "observabilityProcessing": "Queued",
  "correlationId": "c1d2e3f4-a5b6-7890-cdef-123456789012"
}
```

When Agent 365 observability or Purview is enabled, a missing, empty, or invalid
`userContext.tenantUserObjectId` returns RFC 9457 Problem Details with HTTP 400 and
`VALIDATION_FAILED`; no interaction or outbox message is created.

Purview `AuditOnly` synchronously submits two metadata-only content activities that
omit raw content and conversation `agents`, then returns
`purviewProcessing: AuditLogged`. Purview `Enforce` computes policy for the selected
reusable blueprint application location and includes child/blueprint `aiAgentInfo`.
Each prompt (`uploadText`) and response (`downloadText`) activity follows its returned
execution mode: `evaluateInline` requires a synchronous allow/block decision, while
`evaluateOffline` requires successful Graph submission but no response body. All-
inline allow returns `Allowed`; any accepted offline activity produces
`AuditLogged`. An exact `restrictAccess:block` decision returns HTTP 202 with
`status: Failed`, `purviewProcessing: Blocked`, and no observability outbox message.
A missing, unknown, or untrusted Purview mode/decision returns HTTP 503
`PURVIEW_DEPENDENCY_UNAVAILABLE` and persists neither interaction content nor a
receipt.

This route receives a completed prompt/response pair and therefore is not a
pre-model gate. `/api/v1/ai-interactions:evaluate` is not implemented and must not
be called or advertised as available.

---

## 4. Error Model

All errors use RFC 9457 Problem Details:

```json
{
  "type": "https://gateway.example.com/problems/{error-slug}",
  "title": "Human-readable title.",
  "status": 400,
  "errorCode": "STABLE_ERROR_CODE",
  "detail": "Additional context about the specific error.",
  "correlationId": "3f2504e0-4f89-41d3-9a0c-0305e82c3301",
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
| `AGENT_INGRESS_CREDENTIAL_NOT_FOUND` | 404 | Named credential is not owned by the route agent | Administrator credential revoke |
| `AGENT_INGRESS_CREDENTIAL_LAST_USABLE` | 409 | Revocation would remove the last usable key | Issue/deploy/verify a replacement first |
| `CONCURRENCY_CONFLICT` | 409 | ETag/rowVersion mismatch | Stale If-Match header |
| `INVALID_STATE_TRANSITION` | 409 | Operation not valid for current agent state or server-computed safety decision | e.g., enable an already-active agent, retry a non-failed or otherwise unsupported provisioning outcome |
| `PROVISIONING_DISABLED` | 503 | Provisioning execution is disabled for this deployment | Register or retry requested before deployment preflight and execution enablement |
| `PROVISIONING_LEGACY_JOB` | 409 | Operation is not the exact current workflow-v3 shape | Delegated Registry action or retry attempted on v1/v2/noncanonical history |
| `PROVISIONING_STATE_INVALID` | 409 / fail-closed worker result | Persisted provisioning evidence is missing, malformed, nonmonotonic, or mismatched | Unsafe resume, retry, or final verification state |
| `PROVISIONING_AMBIGUOUS_RESULT` | 409 / manual state | External mutation outcome cannot be proved safely | Registry POST without durable returned ID or permanent exact-GET mismatch |
| `PROVISIONING_FAILED` | 422 | Provisioning step failed | Unrecoverable provisioning error |
| `UNSUPPORTED_FEATURE_CONFIGURATION` | 422 | Requested feature combo not supported | e.g., Agent365 observability without prerequisites |
| `PURVIEW_DEPENDENCY_UNAVAILABLE` | 503 | Purview could not return/record a trusted result | Graph error/timeout, processing error, missing/offline scope, missing inline decision, or invalid provisioned identity metadata |
| `AGENT365_DEPENDENCY_UNAVAILABLE` | 503 | Agent 365 dependency unavailable | Timeout from Graph API during provisioning |
| `AGENT365_REGISTRY_ACTION_REQUIRED` | 409 / persisted wait state | Signed-in Administrator must complete workflow-v3 Registry stage | Worker finished its five-stage prefix |
| `AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED` | 401/403/503 | Delegated Graph access, consent, or eligible user context is unavailable | User-only Registry action cannot acquire/use required scopes |
| `AGENT365_REGISTRY_REQUEST_REJECTED` | 409/503 | Registry rejected or returned an invalid nonambiguous request/result | Controlled Registry completion failure |
| `PAYLOAD_TOO_LARGE` | 413 | Request body exceeds maximum size | > 1 MB for batch, > 64 KB for single |
| `SERVICE_UNAVAILABLE` | 503 | Gateway temporarily unable to process | Database or critical dependency down |

### Validation Error Extension

For `VALIDATION_FAILED`, include an `errors` object whose property names map to
arrays of validation messages:

```json
{
  "type": "https://gateway.example.com/problems/validation-failed",
  "title": "Validation Failed",
  "status": 400,
  "errorCode": "VALIDATION_FAILED",
  "correlationId": "3f2504e0-4f89-41d3-9a0c-0305e82c3301",
  "errors": {
    "ExternalAgentId": ["ExternalAgentId is required."],
    "Features.PurviewMode": ["PurviewMode is required when Purview is enabled."]
  }
}
```

---

## 5. Idempotency Semantics

### 5.1 Idempotency-Key Header

| Aspect | Rule |
|---|---|
| **Format** | UUID v4 (`Idempotency-Key: 550e8400-e29b-41d4-a716-446655440000`) |
| **Required on** | All data-plane mutating endpoints (including batch), enable/disable/delete/retry/reconcile where implemented |
| **Not used on one-time secret issuance** | `POST /agents` and `POST /agents/{agentId}/credentials`; their clear-key responses are never cached or replayed |
| **Scope** | `(AgentRegistrationId, Endpoint, IdempotencyKey)`; the same key value is independent across registrations and endpoints |
| **Storage** | `IdempotencyRecord`: registration ID, normalized endpoint constant, key, canonical request SHA-256, safe response, created/expiry timestamps |
| **TTL** | 7 days (configurable via system config) |
| **Same scoped key + same canonical request** | Return cached response with the same status code |
| **Same scoped key + different canonical request** | Return `409 IDEMPOTENCY_CONFLICT` |
| **Missing key (required endpoint)** | Return `400 VALIDATION_FAILED` |

### 5.2 Implementation

1. Resolve and authorize the caller's registration first.
2. Construct the endpoint-specific canonical payload from the typed command: normalize
   timestamps to UTC, retain batch item order, and sort attribute/metadata dictionaries
   ordinally. Serialize it to UTF-8 and store the uppercase hexadecimal SHA-256.
3. Acquire the scope lease for registration ID + normalized endpoint constant +
   normalized UUIDv4 key **before** replay lookup or any side effect.
4. Look up `IdempotencyRecord` inside that lease. If an unexpired record has the same
   hash, return its stored safe response. If the
   hash differs, return `409 IDEMPOTENCY_CONFLICT`.
5. If none exists, process the request while retaining the lease, then stage the
   scoped key, canonical hash, and safe response with the domain write; save and
   complete/commit the lease as the final action.

On SQL Server, lease acquisition starts a ReadCommitted EF transaction and takes an
exclusive, transaction-owned `sys.sp_getapplock` on an opaque SHA-256 resource name.
Its 30-second bounded wait returns fail-closed `409 IDEMPOTENCY_CONFLICT` when it
cannot serialize the scope. The lock is held through all activity/batch domain work
and all interaction Blob/Purview work, idempotency persistence, unit-of-work save, and
commit. Any replay return, conflict, error, or cancellation before completion disposes
the lease and rolls back/releases it. The InMemory provider uses a process-wide keyed
semaphore solely for tests. Focused same-hash, different-hash, and independent-scope
races pass repeatedly; production still requires real SQL Server multi-replica/
staging stress and crash/timeout evidence.

Canonical coverage is the complete typed activity/interaction payload, including
`externalAgentId`; batch hashing includes every item in submitted order. It excludes
the Authorization header, Gateway key, and other secret material. Registration and
credential-issue responses are outside this mechanism so one-time keys can never
enter `ResponseBody`.

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

### 7.1 Implemented local boundary

After Gateway-key authentication/authorization, `IngressRateLimitMiddleware`
enforces three fixed one-minute buckets. It uses the authenticated registration and
credential claims; body `externalAgentId` and obsolete `appid`/`azp` values never
select a bucket.

| Scope | Configuration | Default |
|---|---|---|
| Per Gateway credential | `RateLimitPerClient` | 100/minute |
| Per authenticated registration (aggregates rotated keys) | `RateLimitPerAgent` | 1,000/minute |
| Gateway-wide registration-bound ingress | `RateLimitGlobal` | 10,000/minute |

The SQL Server implementation takes a serializable transaction and
`UPDLOCK`/`HOLDLOCK` over database-UTC global, registration, and credential buckets,
then admits/increments all three atomically. It returns the most constrained scope on
success and the first exceeded scope in global → registration → credential order.
The EF InMemory provider uses a process-singleton lock/store for tests only; it is
not a distributed production fallback. A limiter or configuration dependency failure
returns fail-closed `503 SERVICE_UNAVAILABLE`.

This code and `deploy/sql/20260825_ingress_rate_limit_buckets.sql` are deployed and
verified in development as part of the twice-applied prepare phase. That is not a
production concurrency claim: prove the SQL path across multiple replicas,
failover, timeout, cancellation, and crash conditions before production.

### 7.2 Response

Allowed and rejected registration-bound requests include
`X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset` (Unix seconds), and
`X-RateLimit-Scope` (`credential`, `registration`, or `global`). Rejection also emits
`Retry-After` and `Cache-Control: no-store`:

```json
{
  "type": "https://gateway.example.com/problems/rate-limit-exceeded",
  "title": "Rate limit exceeded.",
  "status": 429,
  "errorCode": "RATE_LIMIT_EXCEEDED",
  "detail": "The Gateway request limit was reached. Retry after the current window resets.",
  "correlationId": "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
}
```

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
| `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`, `X-RateLimit-Scope` | Emitted for registration-bound Gateway-key requests after a limiter decision |
| `Retry-After` | Emitted on `429 RATE_LIMIT_EXCEEDED` |

---

## Phase 3 Completion Checklist

- [x] Complete endpoint catalog for the implemented controllers plus one planned
  control-plane reconciliation operation
- [x] Authentication and authorization rules (2 security schemes, full authorization matrix, identity binding)
- [x] Request/response schemas with examples for exposed operations; the
  planned reconciliation operation remains intentionally outside OpenAPI
- [x] Error model (RFC 9457 Problem Details, stable error codes, validation error extension)
- [x] Atomic scoped idempotency implementation (canonical hash, TTL, replay/conflict, SQL lease)
- [ ] Real SQL Server multi-replica idempotency stress/crash/timeout validation
- [x] Concurrency semantics (ETag/If-Match, optimistic concurrency)
- [x] SQL-backed credential, registration, and global ingress rate limiting
  implemented and deployed in development
- [ ] Multi-replica limiter load, failover, crash, and security validation
- [x] Cursor-based pagination (opaque cursors, parameters, response shape)
- [x] Common headers (request and response)

## Outstanding data and production-readiness work

1. **Finalize remains intentionally unapplied:** The four pre-cutover scripts
   `20260824_agent_identity_workflow_v2.sql`,
   `20260825_agent_ingress_credentials.sql`,
   `20260825_scoped_idempotency.sql`, and
   `20260825_ingress_rate_limit_buckets.sql` are applied and verified in
   development. Run `20260825_scoped_idempotency_finalize.sql` only after a
   successful bounded end-to-end canary, verified inert gates, and zero traffic on
   every old API revision. The three retained failures do not satisfy that boundary.
2. **Distributed runtime proof:** Validate SQL `sp_getapplock` idempotency and the
   three-scope limiter against real SQL Server across multiple API replicas, including
   contention, timeout/cancellation, crash recovery, and load.
3. **Index strategy:** Determine optimal indexes for cursor-based pagination, search, and filtering.
4. **Retention policy implementation:** How to enforce configurable retention for activity receipts, audit events, idempotency records and stale limiter buckets.
5. **Soft-delete behavior:** Which entities use soft-delete vs hard-delete.

## Microsoft Documentation Citations

API design follows established Microsoft REST API guidelines:
- Problem Details (RFC 9457): https://learn.microsoft.com/aspnet/core/web-api/handle-errors
- ASP.NET Core OpenAPI: https://learn.microsoft.com/aspnet/core/fundamentals/openapi/overview
- Rate limiting middleware: https://learn.microsoft.com/aspnet/core/performance/rate-limit
- SQL application lock used for scoped idempotency: https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-getapplock-transact-sql
- Microsoft Identity Web API protection: https://learn.microsoft.com/entra/msidweb/getting-started/quickstart-webapi
- Reusable Agent Identity Blueprint Model: https://learn.microsoft.com/entra/agent-id/agent-blueprint
- Typed Agent Identity Blueprint GET: https://learn.microsoft.com/en-us/graph/api/agentidentityblueprint-get?view=graph-rest-1.0
- Typed Agent Identity Blueprint Principal GET: https://learn.microsoft.com/en-us/graph/api/agentidentityblueprintprincipal-get?view=graph-rest-1.0
- Typed Agent Identity GET and `$expand`: https://learn.microsoft.com/en-us/graph/api/agentidentity-get?view=graph-rest-1.0
- Ordinary App to Agent ID Migration Boundary: https://learn.microsoft.com/entra/agent-id/migrate-custom-app-registrations-to-agent-id
- Autonomous Agent Identity Two-Stage Token Flow: https://learn.microsoft.com/entra/agent-id/autonomous-agent-authentication-authorization-flow
- Gateway and Agent 365 App-Role Assignment: https://learn.microsoft.com/graph/api/serviceprincipal-post-approleassignments?view=graph-rest-1.0
- Direct Agent 365 Registry API (beta): https://learn.microsoft.com/microsoft-365/copilot/extensibility/api/admin-settings/agent-registration/agentregistration-create

All Microsoft Graph API interactions validated in Phase 1 documentation matrix (`docs/architecture/doc-validation-matrix.md`).

## Decisions Needed Before Phase 4

1. **Soft-delete scope:** Which entities use soft-delete? All business records (spec suggests this) or only agent registrations?
2. **Activity receipt content:** Store full prompt/response in the database? The spec says minimize — likely store only metadata and receipt status, not content.
3. **Audit event immutability:** Should audit events be append-only with no update/delete? (Recommended: yes.)
