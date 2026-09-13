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

The source implements the additive
[protection settings](../architecture/protection-settings-plan.md) control plane
for capabilities, tenant connection, SIT inventory, KYD, blueprint DLP profiles,
and durable administration operations. The checked-in OpenAPI document describes
the exact routes.

## Control-plane authorization

The API validates tenant, audience, issuer, user object ID, delegated
`access_as_user`, and Gateway role. Roles are `Gateway.Administrator`,
`Gateway.Operator`, `Gateway.Auditor`, and `Gateway.SupportReader`.

Mutating registration and Registry-completion actions require
`Gateway.Administrator`. The Registry action is user-only and acquires downstream
Graph access through OBO. No app-only Registry fallback exists.

Protection capability reads are available to every Gateway control-plane role.
Operators can also read tenant connection, KYD, and DLP state. SIT inventory and
all protection reviews, confirmations, and mutations require
`Gateway.Administrator`. Every protection request rechecks exact delegated user and
tenant semantics.

Capability records originate only from bootstrap's exact 19-key, ownership/source/
time-bound attestation. Inert startup materializes nothing. Verified runtime startup
strictly validates the full Installed/NotInstalled set and synchronizes it under a
SQL application lock in one deterministic transaction. Partial, drifted, or
identifier-bearing NotInstalled facts fail startup; capability synchronization is
not policy or runtime-readiness evidence.

## Protection administration

Protection mutations use an explicit two-step boundary:

1. a `:review` or `:review-*` route validates the current ETag/row version and
   returns a short-lived, one-time review value plus the exact safe summary;
2. `POST /protection/operation-reviews:confirm` exchanges that value once for a
   short-lived confirmation value; and
3. the matching mutation route requires the confirmation, canonical UUIDv4
   `Idempotency-Key` in both header and body, and matching `If-Match`/row version.

Accepted work returns HTTP 202 and is persisted through the transactional outbox to
`gateway-protection-admin-v1`. Its eight version-1 stages are separate from
registration workflow v3. Reads return ETags where the resource has a row version.
Per-user and per-IP protection-administration rate limits apply before the
controller.

Tenant connection completion also follows review and confirmation. Settings
downloads the canonical Windows companion from the immutable Admin UI image. The
companion opens official interactive Security & Compliance sign-in and emits one
bounded prefixed result. The UI accepts a file containing only that fresh line; the
API validates its digest, operation, inventory generation, tenant, Administrator,
expiry, capabilities, and SIT inventory before independently verifying connection
state.

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

Before **every** model interaction, clients call this route regardless of locally
remembered Prompt Shields or Purview settings:

```http
POST /api/v1/prompts:evaluate
Authorization: Bearer {gateway-key}
Idempotency-Key: {uuid-v4}
```

The Gateway determines which services apply using the current registration.
Disabling Prompt Shields skips its Azure AI Content Safety call; it does not skip
this Gateway route. Purview DLP can still require prompt-side evaluation while
Prompt Shields is off. Operators can change either protection without changing
client flags, keys, or deployment. Clients must not guess the effective policy from
cached registration settings or a previous evaluation.

Only HTTP 200 with `allowed: true`, a non-empty `evaluationReceiptId`, and a
well-formed future `expiresAtUtc` authorizes the model call. Parse the returned
deadline as a timestamp with an explicit time zone and compare its instant against
an accurate current clock immediately before invoking the model, including after
any intervening activity I/O. The sample injects its clock for tests and does not
substitute a fixed lifetime. Missing, malformed, or expired deadlines stop
generation without automatic retry; local validation does not replace the server's
later expiry/context checks or reserve the remaining time.

A receipt is returned even when both services are disabled. Forward
it as `promptEvaluationReceiptId` in the matching AI interaction, retaining the
same external agent ID, interaction ID, tenant user, prompt content type, and exact
prompt content. Every supplied receipt is short-lived, single-use, and bound to the
registration, interaction ID, tenant user, content type, salted prompt hash, and
effective protection context. Never reuse it for another interaction or change the
prompt after evaluation.

Blocked prompts return HTTP 403 Problem Details and no receipt. An unavailable
enforcing Purview path, Prompt Shields failure, unexpected HTTP status, timeout,
or missing/malformed allow response must stop generation rather than falling back
to an unprotected model call. For non-enforcing simulation the Gateway may return
an allowed result with `purviewProcessing: "SimulationUnavailable"`; preserve that
distinction and warn that evaluation was unavailable, not disabled or proof of
protection. Neither that status nor `SimulatedBlock` is a Microsoft-native policy
tip. The sample does not fabricate tips from either result.

The Gateway is not a model proxy. Client code owns the pre-model boundary and
must await a successful allowed evaluation before invoking the model. The sample's
fixed-response callback demonstrates this boundary without a model dependency;
production integrations replace the callback, not the gate.

The receipt binds a dedicated registration protection revision, current protection
flags/mode and identity binding, the effective blueprint profile (including SIT
thresholds, actions, and evidence revision), and active capability/readiness
bindings. Required Prompt Shields and enforcing-Purview decisions must each be
`Allowed`; an overall allow or a matching hash alone is insufficient. An Off-issued
or simulation-era receipt cannot satisfy ingestion under newly enabled Prompt
Shields or enforcing Purview.

The Gateway rechecks this context before issuing favorable proof and again at
ingestion. Current enforcing certification is validated in the same database
scope, including the certified test agent even when it differs from the caller.
The SQL commit phase takes ordered registration shared locks first (caller and
certified test agent), then locks feature/profile and shared
capability/inventory/certification evidence, and finally the receipt.
Existing-agent EF writers take registration **exclusive** locks in the same ID
order before any feature/registration writes, in that same save transaction.
An update lock is not sufficient: it is compatible with the reader's shared lock
and can create a conversion deadlock after a feature write. The registration-first
reader/writer protocol prevents that feature/registration lock inversion.
These row/range locks remain held through commit, so a concurrent protection edit
cannot slip between the check and consumption. Agent last-activity timestamps, unrelated
telemetry changes, and no-op feature updates do not invalidate receipts. Active
profile/capability evidence revisions can invalidate them even when an operator
has not changed the client configuration.

Meaningful lifecycle and downstream-identity changes also advance the protection
revision. In particular, Active -> Disabled -> Active does not resurrect an
unexpired receipt, including when the roundtrip happens during provider work.
These revision updates happen on explicit commands/persisted changes, not during
EF materialization; reading an agent or updating descriptive/telemetry fields does
not advance its protection revision.

Omitting a receipt remains allowed only when current Prompt Shields is off and
Purview is not enforcing. **Any supplied receipt is validated and consumed**, even
when optional. Missing required proof returns HTTP 403
`PROMPT_EVALUATION_REQUIRED`; a supplied unbound, stale, expired, used, or mismatched
receipt returns HTTP 403 `PROMPT_EVALUATION_INVALID`. Context drift detected during
evaluation also returns `PROMPT_EVALUATION_INVALID`, without favorable proof.
Receipt lifetime is bounded by the relevant enforcing-readiness expiry as well
as the configured receipt lifetime.
Evaluation responses and allowed replays serialize that expiry with an explicit
UTC `Z`. SQL `datetime2` deadlines retain their known-UTC ticks when clamped;
they are not interpreted or shifted as machine-local time.

The additive upgrade leaves historical receipts unbound rather than manufacturing
new evidence. Such receipts are rejected when supplied to the upgraded ingestion
path, even if protection is currently off. A cached favorable evaluation is also
rechecked before replay; an already-recorded identical ingestion response remains
an idempotent replay, not a new consumption or evaluation.

A receipt proves an evaluation snapshot, not a configuration lock spanning the
external model call or a guarantee of later acceptance. The Gateway cannot
retroactively stop generation that has already started. Do not silently re-evaluate
to mint replacement proof for already-generated content, repeat a model call, or
blindly retry ingestion. Preserve the original operation identifiers and reconcile
uncertain results before explicitly starting a new interaction. The sample makes
no automatic retries. Ingestion HTTP semantics are unchanged: inspect the
processing fields in an HTTP 202 receipt; a post-model enforcing-Purview block can
record `status: "Failed"` without exporting the interaction.

Data-plane idempotency serialization spans the request using an opaque SQL
session-owned application lock on an unpooled connection, not a long SQL
transaction. Initial receipt/context validation precedes provider work.
Prompt evaluation performs its provider calls before opening the commit
transaction. Interaction ingestion performs Purview processing and stages the
content blob before its short commit transaction rechecks/consumes the receipt and
persists the interaction, outbox, and idempotent response. No provider or blob I/O
runs while the protection row/range locks are held.

Consequently, a protection change during ingestion I/O can reject SQL acceptance
after provider processing or blob staging has already occurred. On a known
pre-commit context rejection, the Gateway releases its transaction/locks before
attempting bounded cleanup of only that attempt's staged blob. Cleanup can fail
and does not claim physical erasure under storage retention/versioning. An
ambiguous commit never triggers blob deletion or automatic ingestion replay;
reconcile it instead. Control-plane idempotency transactions are unchanged.

## Activities and interactions

- `POST /api/v1/agent-activities` accepts sanitized activity events.
- `POST /api/v1/ai-interactions` accepts completed prompt/response records and
  requires the evaluation receipt when the registration is protected. Clients
  should always forward the receipt returned by their pre-model evaluation,
  including when a protection was off at evaluation time.

Ingestion returns HTTP 202 with a correlation ID and processing receipt, not proof
of downstream Agent 365 or Purview landing. For interactions, inspect `status`,
`purviewProcessing`, and `observabilityProcessing`: `Failed` is not successful
processing, and `Queued` is not confirmed delivery. Disabled observability does
not queue an export.

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

Protection administration is additive to the registration contract. Existing
`promptShieldEnabled`, `purviewEnabled`, and `purviewMode` members remain
compatible. Registration and feature-update requests can bind a typed DLP profile
to the resolved blueprint. The API rejects Purview unless that exact profile has
installed capability, exact readback, propagation, token roles, runtime allow and
block evidence, and a current SIT snapshot. Registration never authors policy as a
side effect.
