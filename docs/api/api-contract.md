# Gateway API contract

The checked-in [OpenAPI document](openapi.yaml) is the machine-readable contract.
This page explains the authorization, safety, and lifecycle rules that are easy to
miss when reading individual operations.

## API surfaces

| Surface | Caller | Authentication | Purpose |
|---|---|---|---|
| Health | platform/operator | none | Liveness and dependency readiness |
| Control plane | signed-in tenant user | Entra bearer token | Configuration, registrations, operations, credentials |
| Data plane | external agent | Gateway key | Activities, interactions, prompt evaluation |

Control-plane routes are rooted at `/api/v1`. The Admin UI is a client of these
routes; page-level role checks never replace API authorization.

## Control-plane authorization

The API validates tenant, audience, issuer, user object ID, delegated
`access_as_user`, and Gateway role. Roles are `Gateway.Administrator`,
`Gateway.Operator`, `Gateway.Auditor`, and `Gateway.SupportReader`.

Mutating registration and Registry-completion actions require
`Gateway.Administrator`. The Registry action is user-only and acquires downstream
Graph access through OBO. No app-only Registry fallback exists.

## Registration

Creating a registration accepts display name, environment, blueprint selection, and
optional protection settings plus a proposed external ID. The Admin UI generates
that ID for its user; direct API clients supply one that meets the contract. The API
validates its format and uniqueness, rechecks blueprint compatibility, persists the
registration, and returns a one-time Gateway key after the boundary is accepted.

The clear key appears once. API responses and clients must not log, cache, or place
it in a URL. Losing it requires issuing a replacement and revoking the old key.

## Provisioning operation

Registration starts a durable operation. Clients poll the operation resource or use
the Admin UI. Progress maps to persisted workflow state, including the Administrator
handoff at 71%, accepted Registry creation at 85%, and final verified completion at
100%.

```http
POST /api/v1/operations/{operationId}:complete-agent365-registration
Authorization: Bearer {delegated-user-token}
```

Before the one permitted Registry POST, the API acquires the SQL job lock,
revalidates the completed prefix, acquires delegated access, and persists a
creator-bound planned Registry ID. An ambiguous POST is recovered only by exact GET
of that ID.

## Data-plane binding

Data-plane requests authenticate with a Gateway-issued key and carry the generated
`externalAgentId` in the typed body. The API resolves the key to one registration and
then compares the body binding. A valid key for another registration is rejected.

Mutation requests require a canonical UUIDv4 `Idempotency-Key` header. Idempotency is
scoped by registration and endpoint under a SQL application lock.

## Prompt evaluation and receipt-bound interaction

When a registration enables Prompt Shields or prompt-side Purview, clients call:

```http
POST /api/v1/prompts:evaluate
Authorization: Bearer {gateway-key}
Idempotency-Key: {uuid-v4}
```

An allowed result contains a short-lived evaluation receipt. The client sends it
with the matching AI interaction. The receipt is single-use and bound to the
registration, interaction ID, tenant user, content type, and salted prompt hash.
Blocked prompts return RFC 9457 Problem Details and no receipt.

The Gateway is not a model proxy. The client must prevent the model call when
evaluation blocks or fails.

## Activities and interactions

- `POST /api/v1/agent-activities` accepts sanitized activity events.
- `POST /api/v1/ai-interactions` accepts completed prompt/response records and
  requires the evaluation receipt when the registration is protected.

Accepted ingestion returns HTTP 202 with a correlation ID. Acceptance proves the
Gateway queued work; it does not prove downstream Agent 365 or Purview landing.

## Errors

Errors use `application/problem+json` following RFC 9457. Safe responses include a
stable error code, user-safe detail, correlation ID, and claims challenge where
applicable. Provider bodies, tokens, keys, prompts, and responses are never copied
into Problem Details.

| Status | Meaning |
|---|---|
| 400 | Typed request validation failed |
| 401 | Authentication missing or invalid |
| 403 | Principal lacks authority or a protection blocked |
| 404 | Resource absent within the caller's authorized view |
| 409 | Idempotency conflict or incompatible lifecycle transition |
| 422 | Provider-independent semantic validation failed |
| 429 | Gateway rate limit reached |
| 503 | Required dependency unavailable; operation failed closed |

## Versioning

The public prefix remains `/api/v1`. Additive response fields are permitted; clients
must ignore fields they do not understand. Breaking route or schema changes require
a new API version. Persisted stage numbers and recovery-state fields are separate
storage compatibility contracts.
