# Gateway API contract

The current controller and request/response definitions in `src/Gateway.Api` and
`src/Gateway.Contracts` are authoritative. This page describes the runtime API;
policy definitions and classifiers are managed in Purview.

The local Windows Purview connector uses an explicit, asynchronous connection and
Manual sync contract. It never refreshes the catalog because a page was opened,
focused, or polled. Server/cloud connector support remains deferred in the
[vNext plan](../spec/purview-connector-vnext.md).

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

## HTTPS ingress

The local Compose profile binds the API and Console to loopback HTTP. A hosted
deployment terminates TLS at its reviewed ingress and lists only the canonical
proxy CIDRs in `GatewayIngress:TrustedProxyNetworks`. The API then accepts only
one `X-Forwarded-Proto` hop from those networks. An empty list disables forwarded
header processing; trust-all networks, duplicate entries, non-canonical CIDRs and
more than eight networks are rejected during startup.

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

`POST /api/v1/agents` requires `externalAgentId` to be 3–128 characters, begin
with an ASCII letter or number, and contain only ASCII letters, numbers, dots,
hyphens, or underscores. Invalid values return HTTP 400 with a field validation
entry and have no side effects.

Registry confirmation may return HTTP 503 when Microsoft throttles exact-ID
readback or has not made the record readable. This is an unconfirmed state, not
proof of creation or failure. Refresh the operation and retry its confirmation;
an existing attempt is reconciled by GET and the create request is not repeated.

## Manual Purview connection and Manual sync

The Console reads durable local state and starts provider work only when a Gateway
Administrator explicitly confirms **Connect** or chooses **Manual sync**.
Bootstrap owns the connector identity, certificate, transport key, queue path, and
Windows listener. These values never enter the browser or either mutation body.

| Method and route | Purpose |
| --- | --- |
| `GET /api/v1/protection/purview/connection` | Read durable connector, heartbeat, operation, accepted-catalog, and failure state. This does not contact Purview or start work. |
| `POST /api/v1/protection/purview/connection` | Confirm and queue one connection verification plus initial catalog read. |
| `POST /api/v1/protection/purview/connection/refresh` | Queue one manual catalog refresh for an already recorded connector. |
| `GET /api/v1/operations/{operationId}` | Read the authoritative asynchronous operation state returned by either mutation. |

`GET /api/v1/protection/purview/connection` is `no-store`, returns an `ETag`, and
also returns the same concurrency value as `rowVersion` in the body. Its `state`
is one of `NotConfigured`, `Connecting`, `Connected`, `Refreshing`, `Degraded`, or
`Disconnected`; `refreshMode` is `Manual`. Heartbeat time, last attempt, last
success, catalog retrieval time, policy counts, current operation, sanitized
failure code, correlation ID, and catalog verification status are reported
separately. An old catalog and an unhealthy connector therefore remain visible as
different facts.

An authenticated heartbeat is current for thirty seconds. Outside an active
operation, a missed boundary persists `Degraded` plus
`PURVIEW_CONNECTOR_UNAVAILABLE` when an accepted catalog exists, preserving that
snapshot, or `Disconnected` when none exists. Heartbeat recovery restores only
this liveness-induced state and does not start provider work.

Both mutations require:

- `Authorization: Bearer <Entra token>` with `Gateway.Administrator`;
- one canonical lowercase UUID v4 `Idempotency-Key`; and
- `If-Match` containing the exact `rowVersion` returned by the latest GET.

For the first connection, when GET returns `state: "NotConfigured"` and
`rowVersion: "*"`, send `If-Match: *`. Later requests never use the wildcard. The
connection body is `{"confirmConnection":true}`; the refresh body is `{}`.

An accepted mutation returns HTTP 202 and this shape:

```json
{
  "operationId": "00000000-0000-4000-8000-000000000000",
  "status": "Pending",
  "connectionState": "Refreshing",
  "expiresAtUtc": "2030-01-01T00:10:00Z"
}
```

The accepted response is not proof of connection or refresh success. Poll the
returned operation. Connector operation status is `Pending`, `Running`,
`Succeeded`, `Failed`, `NeedsAttention`, `TimedOut`, or `Cancelled`; terminal
states set `pollingRecommended` to false and identify the connector through
`targetKind: "PurviewConnector"` and `targetId`. For these operations `agentId` is
null. Reusing the same idempotency key with the exact same request returns the same
operation. Reusing it for different input returns 409. A different request while
one is active returns 409 with `currentOperationId`; a stale row version returns
412. Missing or invalid bootstrap-owned connector configuration returns 503.
Brief internal database contention is retried with the exact mutation identity and
reviewed precondition; the caller still receives either the single accepted
operation or a sanitized non-acceptance response.

An authenticated, correctly bound result completed after the original operation
deadline returns `TimedOut` with `PURVIEW_CONNECTOR_TIMED_OUT`; it cannot replace
the accepted catalog. Invalid authentication or operation binding remains
`NeedsAttention` with `PURVIEW_CONNECTOR_RESULT_INVALID`.

## Existing Purview policies

`GET /api/v1/protection/purview/policies` returns the latest connector result that
the Gateway authenticated and accepted into PostgreSQL: `tenantId`,
`retrievedAtUtc`, `source: AcceptedPurviewConnectorSnapshot`, and policy `items`.
Items include policy ID/name, provider mode, enforcement planes, individual
application IDs, public whole-scope `revision`, and
`compatibility: { canAssign, reason }`.

Acceptance verifies connector authentication, request/result binding, configured
tenant, schema, completeness, uniqueness, public `revision`, signed internal
`definitionRevision`, generation, and content hash. Missing or invalid
accepted state returns a failure, never a successful empty catalog. A failed
refresh retains the clearly dated previous accepted snapshot. The cache has no
age expiry and remains usable for review and confirmation during sync or management
unavailability. Only successful manual sync replaces it. Review binds the cached
public whole-scope revision; assignment execution verifies that revision live
before mutation.

The public value deliberately retains the exact deployed legacy digest contract,
including provider policy/rule timestamps and legacy array behavior, so
persisted pre-upgrade values remain comparable. The internal signed value excludes
locations/targets, provider timestamps, and policy display name. It normalizes
only known outer set-like collections and preserves unknown nested-array order.
Catalog access or assignment success proves neither enforcement nor downstream
visibility.

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
The client submits the public whole-scope `revision` for review; the server stores
it in `ReviewedRevision` and sends it through the authenticated assignment request.
The internal signed assignment result contains both post-readback `revision` and
`definitionRevision`; only the latter is stored in `AssignedRevision` as durable
enforcement identity. The public catalog DTO and OpenAPI remain unchanged;
`definitionRevision` exists only in signed internal connector evidence. An
unrelated exact target changes review concurrency evidence but does not invalidate
existing confirmed assignments.
`ASSIGNMENT_RESULT_INVALID` is a terminal non-success result for one pending
operation when its signed response is legacy, incomplete, malformed, or does not
match the request. The Gateway retains that evidence, never infers success or
retries the provider write, and continues processing later operations.

There are no gateway endpoints for creating classifiers, sensitive information
types, policy rules, or shared blueprint profiles. Those policy definitions are
managed in Purview. Bootstrap provisions and owns local connector access; the
connection endpoint verifies that installed access and retrieves a catalog without
collecting credentials from the administrator.

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
The protection-context identity uses stable durable assignment evidence. A trusted
catalog refresh with unchanged internal `definitionRevision` and retained exact
all-accounts target does not become a changed protection context, even when another
exact identity was added and public `revision` changed. Removing or excluding this
identity, narrowing its scope, changing material rule/mode/definition semantics,
or making the policy incompatible changes the context and advances only that
agent's protection revision.
Display-catalog age does not expire the binding or an otherwise valid runtime
request. Receipt lifetime, exact context binding, and required live Graph
protection evidence are still checked independently when the receipt is issued and
consumed.

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

Results distinguish allowed, blocked, failed, partial and unconfirmed processing, with receipt/correlation IDs. HTTP acceptance or a pending export is **not** confirmation of downstream visibility. Agent 365, Purview AI Explorer and Defender delivery depend on the actual agent/deployment configuration and downstream processing. No direct Defender ingestion claim is made by this UI.
