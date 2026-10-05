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
| `POST /api/v1/agents/{id}:enable` or `:disable` | Restore or block gateway admission only; Agent 365 registration is unchanged |
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

### Permanently deregister registered agents

**Settings → Manage Agents** also provides confirmed bulk Disable and Enable actions. Disable transitions Active to Disabled; Enable transitions Disabled to Active. Administrators or Operators may call these gateway-only endpoints. Disabled agents cannot submit new prompts, activities, activity batches or AI interactions. Protection receipts are invalidated by the state change. Agent 365 registrations, Entra identities and protection settings remain intact; already accepted work may finish processing. Each response contains `agentId`, `status` and `effectiveAtUtc`; invalid transitions return 409. The Console refreshes agent lists, detail views and dashboard summaries after each batch.

For permanent deletion, select one or more registered agents, review their names and Registry IDs, and type `DELETE` to confirm. Only Gateway Administrators may delete. Each agent is processed independently, with visible progress and a separate result; a failure does not hide another agent's result.

`DELETE /api/v1/agents/{id}` now requires a JSON body:

```json
{"expectedRowVersion":"<rowVersion from GET /api/v1/agents/{id}>","confirmPermanentDeletion":true}
```

The API first sets the registration to `Deleting`, denying runtime access. Using the administrator's delegated Graph permission `AgentRegistration.ReadWrite.All`, it verifies the exact Registry ID/agent identity/blueprint mapping, deletes the Registry entry, and reads back its absence. Only then does it return HTTP 200 with `status: "Deleted"` and remove the registration from the gateway's active inventory. Local tombstones and audit history remain; there is no gateway restore action. Entra identities, shared blueprints and Purview policies are retained.

Only `Active`, `Disabled`, and retryable `Deleting` registrations with complete mappings are eligible. Stale review versions and active provisioning are rejected. If Microsoft fails or the outcome cannot be verified, the gateway retains the `Deleting` record. Refresh, review its latest version, and confirm again to reconcile deletion. A missing Registry entry is safe to reconcile; a mismatched or unauthorized entry is never deleted. Tokens are neither persisted nor queued. Old local-only deletion queue messages are rejected.

### Test a registered agent from the Console

Use **Test Agent** on the Agents list or an active agent's detail page. The side panel fixes the selected external agent ID and collects its API key and a test prompt. User context defaults to the signed-in administrator's Entra object ID. The key is kept in component memory only, cleared on submission/close, and sent as a Bearer credential exclusively to the same-origin gateway runtime endpoints. No administrator access token is substituted.

The simulator calls `POST /api/v1/prompts:evaluate`, then `POST /api/v1/agent-activities`. If allowed, it also calls `POST /api/v1/ai-interactions` with the same prompt, interaction ID and evaluation receipt. The response is explicitly labeled as simulated; no model is invoked. Blocked prompts do not produce a simulated AI response. The gateway's configured Prompt Shields, Purview and observability paths execute normally, including configured blocked-prompt telemetry. Each request has its own idempotency key; uncertain requests are never automatically replayed.

Results distinguish allowed, blocked, failed, partial and unconfirmed processing, with receipt/correlation IDs. HTTP acceptance or a pending export is **not** confirmation of portal visibility. Agent 365, Purview AI Explorer and Defender delivery depend on the actual agent/deployment configuration and downstream processing. No direct Defender ingestion claim is made by this UI.
