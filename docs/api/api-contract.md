# Gateway API contract

The current controller and request/response definitions in `src/Gateway.Api` and
`src/Gateway.Contracts` are authoritative. This page describes the runtime API;
policy definitions and classifiers are managed in Purview.

## Interactive reference and schema

Open `/docs` on the API listener or through the Console (default
`http://127.0.0.1:5081/docs`). The Console sidebar links to this Scalar reference.
The live OpenAPI contract is generated from controllers and DTOs at
`/openapi/v1.json` and `/openapi/v1.yaml`; protected operations retain their normal
authorization when called from the reference. Interactive requests affect the live
installation. Do not share credentials pasted into the reference.

| Scheme | Use |
| --- | --- |
| `EntraBearer` | Entra access token for the Gateway API audience; endpoint-specific gateway roles apply |
| `AgentKey` | Gateway-issued secret for the registered external agent; not an Entra JWT |

Both schemes use the `Authorization: Bearer` header. The endpoint's security
requirement selects the scheme. Registration confirmation additionally requires
a delegated administrator token and the API's consented Graph Registry scopes.

Refresh the checked-in schema after rebuilding and starting the API:

```powershell
Invoke-WebRequest http://127.0.0.1:5080/openapi/v1.yaml -OutFile docs/api/openapi.yaml
pwsh -NoProfile -File tools/scripts/diagnostics/Test-GatewayApiDocumentation.ps1
```

Use the [README evaluation/interaction example](../../README.md#call-the-agent-api)
for a complete pre-model gate. Do not retry uncertain one-time key issuance or
registration creation blindly; reconcile authoritative state first. A `202`
response acknowledges queued work, not policy propagation or remote visibility.
Error responses describe failure with HTTP status and, where provided,
`errorCode` and `correlationId`. Protection updates require matching reviewed
`If-Match` and `Idempotency-Key` headers. Refresh and review again on conflicts.

## Console administration

Console requests use Entra authentication and gateway authorization policies.
Registration creates an individual agent under the selected existing or new
blueprint. Purview policy selection is performed after registration.

| Method and route | Purpose |
| --- | --- |
| `GET /api/v1/agent-identity-blueprints` | Discover selectable blueprints |
| `POST /api/v1/agents` | Register an agent; returns operation and one-time gateway credential |
| `GET /api/v1/agents` | Search and paginate registrations |
| `GET /api/v1/agents/{id}` | Read registration and protection state |
| `PATCH /api/v1/agents/{id}/features` | Update supported feature choices |
| `POST /api/v1/agents/{id}:enable` or `:disable` | Change lifecycle state |
| `DELETE /api/v1/agents/{id}` | Request agent deletion |
| `POST /api/v1/agents/{id}:retry-provisioning` | Retry eligible provisioning |
| `GET /api/v1/agents/{id}/credentials` | List credential metadata |
| `POST /api/v1/agents/{id}/credentials` | Issue a one-time credential |
| `DELETE /api/v1/agents/{id}/credentials/{credentialId}` | Revoke that credential |
| `GET /api/v1/agents/{id}/audit-events` | Administrative history |
| `GET /api/v1/agents/{id}/provisioning-history` | Provisioning history |
| `GET /api/v1/operations/{id}` | Authoritative provisioning status |
| `POST /api/v1/operations/{id}:complete-agent365-registration` | Delegated administrator Registry confirmation |
| `GET`, `PATCH /api/v1/system/config` | Read/update supported gateway settings |

Protection feature/settings mutations require matching `Idempotency-Key` and
`If-Match` headers and corresponding request fields. A stale version fails; the
client must reload before submitting a newly reviewed mutation. The Console must
not automatically repeat an uncertain credential issuance or Registry mutation.
Registration and credentials use no-store responses; issued secret values are
shown once and must not enter query caches or logs.

## Existing Purview policies

`GET /api/v1/protection/purview/policies` returns a tenant-bound signed catalog:
`tenantId`, `retrievedAtUtc`, `source: Purview`, and policy `items`. Items include
policy ID/name, provider mode, enforcement planes, individual application IDs,
definition revision, and `compatibility: { canAssign, reason }`.

The API verifies signature, configured tenant and freshness. Missing, stale,
invalid or unavailable catalog access returns a failure, never a successful empty
catalog. Catalog access alone proves neither assignment access nor enforcement.
Bootstrap configures the certificate-backed Windows catalog host and public-key
binding. Settings only displays ongoing diagnostics.

| Method and route | Purpose |
| --- | --- |
| `GET /api/v1/agents/{id}/purview-policies` | Read assignment states and observed allow/block evidence |
| `POST /api/v1/agents/{id}/purview-policies/review` | Review `{ policyId, revision }` for the exact agent |
| `POST /api/v1/agents/{id}/purview-policies/{operationId}/confirm` | Confirm the reviewed assignment |

Assignment adds the individual agent identity to the selected compatible policy;
it preserves unrelated scope, exclusions, rules and mode. The shared blueprint
must never substitute for that identity. Assignment completion, synchronization,
observed enforcement and failure are separate states. The catalog host performs
the authenticated assignment/readback; the Console polls authoritative status.

There are no gateway endpoints for creating classifiers, sensitive information
types, policy rules, shared blueprint profiles, or initial Purview connections.
Those policy definitions are managed in Purview; tenant access is set up by bootstrap.

## Agent ingress

Testing and external agents call the gateway using their own gateway credentials.

| Method and route | Purpose |
| --- | --- |
| `GET /api/v1/agent-runtime/readiness` | Read authenticated runtime readiness |
| `POST /api/v1/prompts:evaluate` | Evaluate a prompt before the external model runs |
| `POST /api/v1/ai-interactions` | Submit the interaction under the receipt contract |
| `POST /api/v1/agent-activities` | Submit one activity |
| `POST /api/v1/agent-activities:batch` | Submit an activity batch |

The gateway calls Microsoft Graph Purview `processContent`; Purview does not call
a gateway `processContent` endpoint. A prompt receipt binds the exact registration,
content and protection context. Expired, replayed or changed-context receipts
cannot authorize a different interaction. Prompt Shields and Purview are separate
evaluations. An unavailable required protection service is not an allowed verdict.

`GET /health` and `GET /health/ready` expose service health/readiness. Deployment
readiness alone does not establish live policy blocking or sibling isolation.
