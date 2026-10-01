# Gateway API contract

The checked-in [OpenAPI document](openapi.yaml) is the machine-readable contract.
This page explains the authorization, safety, and lifecycle rules that are easy to
miss when reading individual operations.

This guide describes the source contract. Local fixtures, live health,
authorization-boundary probes and signed-in product journeys have different
scopes; one must not be substituted for another.

## HTTPS ingress

Private runtime-test review/execution/readback and runtime-test confirmation
require the effective request scheme to be HTTPS. The API processes only
`X-Forwarded-Proto`, before authentication/authorization, from explicitly configured
`GatewayIngress:TrustedProxyNetworks`. The default empty list trusts no forwarded
scheme; direct HTTPS remains supported. Invalid, duplicate, noncanonical or
trust-all CIDRs fail startup instead of silently broadening the boundary.
A missing network peer cannot establish forwarding authority either.

The supported Container Apps deployment binds the reviewed platform ingress
range `100.100.0.0/17`; public peers and the separately observed workload range
are not trusted by that setting. IPv4-mapped peers use the same boundary.
Forwarded host and client-IP headers do not gain authority from this configuration.
Container Apps overwrites client-supplied protocol headers at its TLS terminator.
Canonical verification checks the request-derived public HTTPS origin even when
the client supplies misleading forwarding headers. A changed platform hop requires
reviewed configuration and new verification, not clearing the proxy allowlist.
See the platform's [ingress-header contract](https://learn.microsoft.com/azure/container-apps/ingress-overview#http-headers)
and [reserved network ranges](https://learn.microsoft.com/azure/container-apps/custom-virtual-networks#subnet).

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

OAuth clients request the resource-qualified
`api://<Gateway API application ID>/access_as_user` scope. Gateway role names are
not OAuth scopes. The static OpenAPI uses `x-gateway-roles-any-of` to document
alternative allowed roles separately; replace its tenant and API application
placeholders with verified deployment values before configuring OAuth tooling.
The documented health routes are at `/health` and `/health/ready`, not under
`/api/v1`. The host also maps operational `/health/checks` and
`/health/bootstrap-attestation` probes, which are not catalogued in the static
OpenAPI document.

Registration creation, feature changes, credential management, deletion,
provisioning retry and Registry completion require `Gateway.Administrator`.
Administrators and operators can enable or disable registrations and read their
provisioning operations/history; auditors can read audit history alongside
administrators. The Registry action is user-only and acquires downstream Graph
access through OBO. No app-only Registry fallback exists.

Protection capability reads are available to every Gateway control-plane role.
Operators can also read tenant connection, KYD, and DLP state. SIT inventory and
all protection reviews, confirmations, and mutations require
`Gateway.Administrator`. Every protection request rechecks exact delegated user and
tenant semantics.

Initial capability records come from bootstrap's exact 19-key, ownership/source/
time-bound attestation. Inert startup materializes nothing. Verified runtime startup
strictly validates the full Installed/NotInstalled set and synchronizes it under a
SQL application lock in one deterministic transaction. A separate capability
preparation path requires matching authorization and a receipt/history chain;
original bootstrap configuration cannot overwrite that upgraded projection.
Partial facts, unauthorized drift, or identifier-bearing NotInstalled facts fail
validation. Capability synchronization is not policy or runtime-readiness evidence.

## Protection administration

Protection mutations use an explicit review, confirmation, and execution boundary:

1. a `:review` or `:review-*` route validates the current ETag/row version and
   returns a short-lived, one-time review value plus the exact safe summary;
2. `POST /protection/operation-reviews:confirm` exchanges that value once for a
   short-lived confirmation value; and
3. the matching mutation route requires the confirmation, canonical UUIDv4
   `Idempotency-Key` in both header and body, and matching `If-Match`/row version.

Queued administration work returns HTTP 202 and is persisted through the
transactional outbox to `gateway-protection-admin-v1`. Its eight version-1 stages are separate from
registration workflow v3. Reads return ETags where the resource has a row version.
Per-user and per-IP protection-administration rate limits apply before the
controller.

For an ordinary protection start, the review token ID is also the durable
operation ID. Companion completion is different: its review authorizes
continuation of the reviewed `sourceOperationId`, not a new connection. Settings
awaits browser acknowledgement of the execution/recovery ID in the `operation`
query parameter before confirmation or mutation: the original source ID for
completion, the review ID for ordinary starts. Confirmation still binds the
separate approval ID. Failed retention sends neither request. Cancelled, expired
or changed reviews cannot dispatch through late callbacks. Unknown outcomes use
GET of the retained operation, never replacement consent or another create.

The browser recovery guard retains its current scroll fragment, which may differ
from the server navigation URI after a same-page shortcut. Origin, path, other
query parameters and the exact single recovery identifier must still match the
intended context. A fragment is presentation, not a different operation or
profile. Failed acknowledgment, JavaScript failure, disconnection or an interop
timeout before dispatch sends no confirmation/mutation and gives explicit
reload/status/review guidance. Logs include only the operation ID and failure
type, not evidence or raw exception text. This pre-dispatch handling does not
reclassify errors after submission as safe to retry.

Tenant connection completion also follows review and confirmation. Settings
downloads the canonical Windows companion from the immutable Admin UI image. The
companion opens official interactive Security & Compliance sign-in and emits one
bounded prefixed result. The UI accepts that fresh line directly in **Paste
companion result**; uploading an already saved text file is optional and uses the
same parser. No manually created file is required. Surrounding whitespace is
ignored; console history, duplicate result lines, raw JSON and reference-repair
output are rejected. The input remains bounded to 512 KiB of UTF-8 text and
384 KiB of decoded payload. Interactive Server uses a finite 1 MiB inbound
message limit so a realistic classifier inventory can reach these checks without
exceeding SignalR's default 32 KiB. Editing or replacing input invalidates the
previous local evidence and completion review; late file reads cannot overwrite
a newer paste. Raw pasted text stays only in component memory and is cleared
on submission, task reset or disposal; the page does not persist it. The
API validates its digest, operation, inventory generation, tenant, Administrator,
expiry, capabilities, and SIT inventory before independently verifying connection
state.

Completion acceptance returns the original `ConnectPurviewTenant` operation ID
and moves that operation to `Pending`. Its separate
`CompletePurviewTenantConnection` approval becomes `Submitted`, with
`readbackReferenceId` pointing to the original operation. The connection resource
becomes `PendingVerification`, not `Connected`. Settings can recover an old
Submitted approval URL with one GET hop only after validating the reference and
both records' tenant, actor, target, type and accepted state. Read-only viewers
retain the server's existing tenant/role permissions; this does not grant mutation
or companion-download authority. Failed, malformed or mismatched references are
not followed. A failed connection resource is `VerificationFailed`. A nonretryable
worker verification failure records `RequiresManualIntervention` on the operation
and active step, leaving later steps Pending and unrun. The UI presents that
status as Failed and exposes only the bounded failure code and correlation ID.

`GET /protection/operations/{operationId}` can return optional `companionLaunch`
instructions for the same actor's accepted `ConnectPurviewTenant` operation while
it is `AwaitingAdministrator`. These are the original operation, tenant, actor,
inventory generation and expiry bindings. Readback neither starts a connection
nor refreshes its deadline or grants authority. The UI checks those bindings and
current time again before offering the command or accepting companion evidence.

Settings observes only the retained pending operation through this GET route.
Its three-second polling cadence is bounded to five minutes, with explicit
stop/resume; terminal results trigger fresh current-state GETs. A read error,
deadline or route change stops observation without replaying any POST. A failed
current-state refresh cannot turn historical `Completed` into current readiness.
Refresh success is evaluated against the current task's required reads, not an
unrelated error retained from another task. Replacement runtime-readiness expiry
also updates the parent's expiry boundary without changing its private sample
context.
These are client behavior changes, not new API permissions or request fields.
The Settings-only `profile` query parameter carries an exact saved profile into
the next task; it does not grant access or replace server-side binding checks.

### Current protection snapshots

The additive optional fields do not change request authority:

| Response field | Meaning |
|---|---|
| `readiness.validUntilUtc` | Earliest current connection/inventory expiry, additionally bounded by behavior-evidence expiry for Enforce; null when a usable bound cannot be established. |
| `features.purviewProfileStatus` | Saved shared profile state, separate from `purviewConfigurationStatus`, which describes an operation. |
| `ProtectionAdminOperationResponse.companionLaunch` | Existing non-secret accepted launch parameters for same-actor recovery, not new consent. |

Expiry equality is expired. The shared UI projection does not infer current
enforcement from missing expiry metadata, a completed operation or a historical
test report. A known bound is only a snapshot: changed identity, policy, inventory
or other context can invalidate readiness earlier. Intentionally Off is neutral,
unknown remains unknown, and simulation never establishes enforcement.

### Shared DLP configuration

A blueprint DLP profile can select 1–100 distinct sensitive information types
(SITs) from one current inventory generation. `sensitiveInformationTypes` is the
multi-selection field; the legacy `sensitiveInformationType` remains accepted and,
when both are supplied, must agree with one selection. A rule matches **any**
selected SIT (OR); counts are not summed across SITs.

Each selected SIT has explicit count and confidence thresholds: `minCount >= 1`,
`maxCount = -1` for any upper count or `maxCount >= minCount`, and inclusive
confidence bounds from 1 to 100. New-policy reviews fill omitted thresholds with
1, -1, 75, and 100 and return those values for review. Existing-policy omissions
can preserve only proven readback values. Unverified legacy thresholds require
all four values for every SIT and an explicitly reviewed full replacement.

`policyMode` supports `Enforce`, `SimulationWithTips`, `SimulationWithoutTips`, and
`Disabled`. Keep legacy `mode` compatible: `Enforce` for enforcing, `AuditOnly` for
the other modes. Omitted `policyMode` maps legacy `AuditOnly` to
`SimulationWithoutTips`. Mode names do not prove runtime enforcement or a native
policy tip. Updating an existing profile requires
`acknowledgeSharedPolicyImpact: true`; the review reports
`affectsAllBlueprintAgents` because the policy applies to the shared blueprint.

The UI treats an unrecognized current or legacy mode as review-required rather
than silently choosing simulation. Invalid supplied thresholds are not repaired
by defaults; existing unproven values need explicit reviewed replacement.

`ReconcileDlpProfile` reviews the unchanged saved profile against the current
connection's active inventory, not a stale generation retained on that profile.
The review summary identifies that generation and the read-only Microsoft
check. Review/confirmation alone do not rebind a profile. Acceptance rechecks
the exact tenant, connection, profile/row version, blueprint, name, mode,
selections/thresholds, activities/actions and current inventory. Only its
accepted transaction can replace an older profile generation/expiry, mark
verification pending and clear old propagation/token/runtime certification.
Provider IDs, saved settings, historical readback time and agent choices are
preserved. Later worker reconciliation remains read-only; drift after review
rejects acceptance rather than silently changing the reviewed intent. This
changes validation/recovery semantics, not routes, payload fields or permissions.

### Approved sample runtime tests

The administrator-only HTTPS runtime-test routes are:

| Method and route under `/api/v1` | Contract |
|---|---|
| `POST /protection/purview/dlp-profiles/{profileId}:review-runtime-test` | Review a sample manifest and one batch; matching `If-Match` is required; returns HTTP 200 and a review token |
| `POST /protection/purview/dlp-profiles/{profileId}:test-runtime` | Execute the confirmed batch with matching `If-Match` and `Idempotency-Key`; returns HTTP 200 with the structured result |
| `GET /protection/runtime-tests/{operationId}` | Read a tenant/actor-bound result and recover expired running work without resubmitting content |

Exchange the review token through `POST /protection/operation-reviews:confirm`
before execution. Runtime-test action responses use `Cache-Control: no-store` and
`Pragma: no-cache`. The two POST routes require `application/json`, reject unknown
JSON properties, cap request bodies at 1 MiB and JSON depth at 12, and reject raw
samples that do not match the reviewed manifest.

For browser execution, raw text remains in the private JavaScript module rather
than Blazor component/circuit state. The Admin UI's separate
`GET /portal/protection/runtime-tests/antiforgery` and
`POST /portal/protection/runtime-tests/{profileId}/execute` endpoints require an
authenticated Gateway Administrator and HTTPS; execution validates antiforgery,
body shape and byte bounds. The portal confirms the review and submits its one
execution request to the Gateway API as that user. These portal routes are not
new `/api/v1` operations or an app-only bypass.

The UI rechecks administrator access, profile/version, tenant/actor, inventory,
mode, approved suite and expiry before dispatch. Cancel, context changes and
expired review/inventory invalidate local approval; late results for an old
binding are ignored. The backend's 60-second execution deadline uses its injected
clock and bounds awaited dependencies as well as signalling cancellation.
Cancellation or timeout is not proof that remote work did not occur: recover the
safe report by GET instead of resubmitting samples.

The full suite has one positive example intended for each selected SIT and one
clean negative example, with distinct case IDs and content commitments. A batch
selects 1–8 positive case IDs plus the negative example. Each sample is 1–8192
UTF-8 bytes; the batch including its negative is at most 65536 bytes. The review
contains hashes and lengths only and requires `acknowledgeSyntheticData: true`.
Execution carries the exact approved content in its TLS request body. Raw samples
are ephemeral and are not persisted as operation state or returned in results.

To commit content, use a fresh 32-byte nonce encoded as 64 lowercase hexadecimal
characters. Compute SHA-256 over the UTF-8 bytes of
`A365Gateway.PurviewRuntimeTest.Sample.v1` followed by a NUL byte, the decoded nonce,
the content's four-byte little-endian UTF-8 byte length, and the exact UTF-8 content.
Encode the digest as `sha256:` plus 64 lowercase hexadecimal characters. The
manifest separately binds each case ID and intended SIT. Do not trim or normalize
content after review.

The review identifies the actual active registration and child identity selected
by the server, the shared blueprint, policy mode, inventory, thresholds, and
configuration/context fingerprints. Results distinguish partial coverage,
enforcement behavior, simulation, submission acceptance, failure, and unknown
outcomes. `enforcementBehaviorVerified` is distinct from a completed operation or
a successful HTTP response. `verificationScope` is
`ApprovedSampleBehaviorInEffectivePolicyScope` and `sitMatchAttribution` is
`Unavailable`: observed blocking does not identify which SIT matched. Historical
results do not replace current profile readiness; evidence expires and context
changes invalidate it. Read status after an interrupted execution; do not
automatically replay provider work or raw sample submissions.

Portal and UI report validation checks the operation identity, known states and
modes, hashes, row-version shape, bounded unique cases and safe failure codes.
An enforcement-verification claim additionally needs a completed Enforce result
with no outstanding cases/failures, a processed allowed negative, and processed
blocked positives with content-action evidence. Contradictory metadata cannot
produce a success badge. Immediate/recovered reports also remain bound to the
reviewed suite/configuration when that context is present; the saved-report route
does not borrow a previous route's result or fabricate the originating agent.

The legacy `:review-runtime-validation` and `:validate-runtime` routes remain
mapped for compatibility but reject valid requests with HTTP 422
`PURVIEW_RUNTIME_SAMPLES_REQUIRED`. Use the explicit sample workflow above.

## Registration

Creating a registration accepts display name, environment, blueprint selection, and
optional protection settings plus a proposed external ID. The Admin UI generates
that ID for its user; direct API clients supply one that meets the contract. The API
validates its format and uniqueness, rechecks blueprint compatibility, persists the
registration, and returns a one-time Gateway key after the boundary is accepted.

Registration and feature updates can bind a compatible existing DLP profile or
carry `purviewConfigurationIntent`: a one-time confirmation token, idempotency
key, and expected row version from a reviewed DLP configuration. This is explicit
consent to that exact configuration. For a new blueprint, the review carries
`deferredBlueprint` with the exact external agent ID and blueprint display name,
an empty blueprint GUID, and no existing profile ID. Registration binds the
reviewed intent to its newly created blueprint before policy work proceeds. This
consent cannot be reused for another registration or blueprint. Configuration
operation ID/status fields expose progress separately from effective readiness.
Do not combine configuration intent with an existing profile selection. Deferred
configuration remains `AwaitingBlueprint` until the registration is Active and
its exact new identity binding is available; stale authority/inventory or an
existing conflicting shared policy requires a fresh review or manual action.

The clear key appears once at registration acceptance, before Registry completion.
Store it securely before continuing to the administrator handoff; readback cannot
recover it. API responses and clients must not log, cache, or place it in a URL.
Losing it requires issuing a replacement and revoking the old key.

The current Admin UI orders registration as identity, blueprint and feature
choices, followed by an explicit review. Defaults requested On remain On when
protection prerequisites are unavailable; the administrator must resolve the
prerequisites or explicitly choose Off. Changed choices or readiness invalidate
the reviewed submission. The one-time handoff shows the endpoint, external ID
and key, with a saved-key acknowledgement and guarded navigation before continuing.
A non-secret PowerShell sample command is offered only for HTTPS. A local HTTP
loopback endpoint may be displayed, but the UI instead explains that a trusted
HTTPS endpoint is required before running the external-agent sample.

Before dispatching a create, the UI awaits browser acknowledgement that its URL
retains the non-secret external ID in a `pendingExternalId` query parameter.
Missing or failed acknowledgement, including disconnection during retention,
prevents the registration POST. Reloading the retained URL enters recovery instead
of sending another create. Recovery searches for the exact external ID through
at most ten pages; no match or a bounded/incomplete lookup does not authorize
another create. A found registration with a lost key needs credential replacement,
not a replacement registration. The URL is neither a credential nor permission
to complete Registry work.

Credential metadata and mutation remain administrator-only. The detail page
uses the same one-time handoff for replacement keys, asks the administrator to
verify replacement deployment before revoking the selected old key, and guards
against revoking the last usable key. It reads only role-permitted audit and
provisioning history. Late responses for a previously selected registration are
ignored; an uncertain mutation requires current metadata readback before another
action. Deletion wording explicitly preserves linked Microsoft resources.

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

The operation page checks the requested operation and agent bindings, the signed-in
administrator role, and `agent365RegistrationCompletionAvailable` before offering
completion. Automatic completion additionally consumes a one-time saved-key permit
bound to that operation/agent in the current Blazor circuit. A URL flag, direct
visit or reopened circuit does not supply that permit. Manual completion requires
an active confirmation bound to the operation and agent, consumed before dispatch.
Cancelled or hidden confirmation callbacks are ignored; late async results from
older route generations cannot replace the current operation state. The same API
authorization remains required.

Polling is bounded to five minutes, including in-flight status work. Reaching
that bound pauses the UI, not the durable operation. Legacy, terminal or
server-disallowed polling states stop automatic updates. Failed reads label
previous progress stale and disable completion. Unknown completion results offer
recorded-status readback, not another create; that UI read does not itself promise
a fresh Microsoft provider readback. Consent/claims challenges retain the same
operation and require administrator interaction rather than an automatic retry.

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
Prompt Shields is off. Administrators can change either protection without changing
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

The external-agent sample returns exit `0` only after both activity and interaction
responses are HTTP 202 with nonempty, matching receipt identities and recognized
nonfailing processing fields. Its final `[ACCEPTED]` summary is not completed
processing or downstream delivery; per-step `[ACCEPTED]` lines describe only their
own request. A malformed/unbound 202 is `[UNKNOWN]`; a receipt reporting
failure, unknown processing or an error is `[FAILED]`; both return `4`. Evaluation
403 returns `[BLOCKED]` and `3`, without a model call. Other runner failures return
`4`; argument/key-format rejection remains the entry point's exit `2`.
Responses and exception bodies are not printed. The sample retains the original
receipt for its single post-model submission and does not refresh proof or repeat
generation after expiry or context rejection.

The current activity DTO also accepts tool details and custom attributes that
are not retained by the receipt/outbox telemetry projection. Custom activity has
an Azure Monitor mapping but no Agent 365 mapping. Single-activity validation is
not yet identical to batch validation; duplicate new IDs in the same batch can
fail at SQL uniqueness enforcement rather than return per-item rejection.
Do not infer rich tool analytics or all-destination delivery from acceptance.

## Agent listing

The current list handler and repository use the same versioned opaque cursor over
creation time and Gateway ID, in ascending order. Pass `nextCursor` back unchanged;
malformed or legacy GUID cursors return validation HTTP 400 rather than starting
a different page. An exactly full final page has no continuation cursor.

Search is a trimmed, case-insensitive literal substring of name or external ID,
not description. Status and environment filters combine with that search.
`totalCount` covers the full filtered query before the cursor, not the current page
or remaining rows. The current controller defaults to 50 items and validation
accepts 1-200; clients should restart without a cursor when changing filters.

The Admin UI uses 100-item pages with Previous/Next history, filter reset and safe
restart for invalid cursors. Overview obtains full-query totals separately from
its small task preview. Missing totals remain unavailable, not zero. These are
live, separate reads rather than a snapshot across pages or status counts;
registrations can change while browsing, so refresh after lifecycle changes.
Neither counts nor recent activity establish protection or telemetry delivery.

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

The client, listing and protection behavior above is implemented in application
source. Current provider behavior must be verified independently; local fixtures
do not add API routes, roles or schema guarantees.

The public prefix remains `/api/v1`. Additive response fields are permitted; clients
must ignore fields they do not understand. Breaking route or schema changes require
a new API version. Persisted stage numbers and recovery-state fields are separate
storage compatibility contracts.

Protection administration is additive to the registration contract. Existing
`promptShieldEnabled`, `purviewEnabled`, and `purviewMode` members remain
compatible. Requested configuration, pending configuration work, policy mode, and
effective protection are separate response fields. Enforcing readiness requires
the applicable installed capability, exact policy/threshold readback, propagation,
token roles, current inventory, and approved runtime evidence. Queued configuration
or registration acceptance alone does not establish that readiness.
