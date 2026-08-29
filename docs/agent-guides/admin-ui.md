# Admin UI implementation guide

This guide is the shared source of truth for Claude and Codex agents working on `Gateway.AdminUi`.

When changing registration, provisioning history, or operation-status screens,
also read `docs/implementation-status.md` and
`docs/agent-guides/provisioning.md`.

## Authority order

1. Implemented API controllers and `Gateway.Contracts` types.
2. The deployed OpenAPI document when validating the running Azure API.
3. `docs/api/openapi.yaml` and `docs/spec/full-spec.txt` for intent.
4. Agent and skill playbooks.

When these disagree, follow the implemented/deployed contract and record the discrepancy. Do not fabricate a route to satisfy an aspirational screen.

## Provisioning truth boundary

The operation endpoint returns persisted Gateway job state. The registration
handler pre-creates ordered step rows, and the Admin UI renders the rows returned
by the API. A real operation ID, progress value, or Completed step is not by
itself proof that an Entra or Agent 365 resource exists.

The compatibility-aware Admin UI and workflow-v3 API/worker are live continuously in
development. Staging and production remain closed by default. The last independently
captured authenticated typed-catalog inventory contained 12 rows: 7 compatible/
selectable and 5 incompatible/disabled; a later user-run create-new flow was reported
successful, so recapture the catalog before treating those counts as current. Three bounded v2
canaries remain manual evidence and the v2 queue is zero active, zero scheduled,
and DLQ3:

1. The incompatible `pat-blueprint` operation failed GET-only at
   `ResolveBlueprint` and made no Microsoft mutation.
2. The compatible `simple-echo-agent Blueprint` operation received HTTP 201 from
   exactly one FIC POST, then failed closed at `ConfigureGatewayFederation` after an
   immediately stale list read. Later read-only reconciliation proved exactly one
   correct reusable FIC. No child Agent ID, Agent 365 role assignment, Registry
   record, or telemetry mapping was created.
3. The confirmed third registration GET-reused the FIC, created and verified child
   `8e4859bd-477c-4133-adb1-9030ec13bf5c`, assigned OtelWrite, then received HTTP 500
   from its one Registry POST without a durable ID. It remains manual at 71%.

The redacted evidence files are
`docs/operations/evidence/canary-failure-20260825.json`,
`docs/operations/evidence/canary-federation-failure-20260825.json`, and
`docs/operations/evidence/canary-registry-failure-20260826.json`. None may be
retried, attached, deleted, or presented as usable. Exact portal searches after
Refresh returned 0 of 341, but that is not API proof.

Current local source is workflow v3. The worker stops after five stages at 71% and
the operation status exposes `requiredAction=CompleteAgent365Registration`. In
continuous development the Administrator UI invokes the typed completion endpoint
once automatically and resumes bounded polling; exact-bound deployments render the
safe explicit handoff. Auditors/support readers get no action. No upload, JSON file,
token paste, or CLI step is part of the flow.

Current live UI state includes Active create-new registration
`fb35a5ce-8df5-48c2-86e9-9411d17df070` and Active reusable-blueprint registration
`ff685604-999c-4584-9cec-87ec21f870ee`. Both are visible and Available in Microsoft
365 Admin Center. The reusable-blueprint registration proves benign Purview
`AuditLogged` and synthetic prompt `Blocked`; its `downloadText` scope is offline.
Latest Admin UI tests are 151/151; consult the implementation status for the exact
identity mappings, deployment revisions, and complete release counts.

Historical superseded checkpoint: the first fresh workflow-v3 registration used external ID
`agent-v3demo-20260827030009-3c870882` maps to Gateway registration
`583777f0-c601-4c09-9e28-27dab51ae375` and operation
`5c4ba41d-24e5-473c-9126-f89f37f7bb18`. Worker stages 1--5 completed. One
Administrator action crossed the Registry create boundary exactly once and returned
an ambiguous outcome before a durable ID. The operation is
`RequiresManualIntervention` at 71%; the UI must render the non-replayable manual
state and no completion action. No stage-7 enqueue, data-plane proof, or telemetry
landing exists. The one-time key was issued;
only safe key ID `47b13283-5be7-4fc2-88d2-7fef34642214` may be documented.

In that historical attempt the user reached and exercised the exact completion action once. Two earlier pre-
POST responses exposed production scope-claim mapping and Graph string-ID validation
defects; both are fixed. The later create outcome is ambiguous and must never be
repeated. Its reconciliation-only resume path is superseded by the distinct Active
canary above.

UI copy must describe Gateway-reported state and must not promise successful
Microsoft-side provisioning until the provisioning guide's definition of done is
met. Verify external results only through an authorized, documented backend
mechanism—never by inventing a UI API or using the failed registration as a visual
smoke test.

## Portal architecture

- .NET 10 Blazor Web App with Interactive Server rendering.
- Microsoft Fluent UI Blazor for controls and visual language.
- Microsoft Identity Web for single-tenant Entra sign-in and delegated API tokens.
- A scoped typed API client owns authorization headers, correlation IDs, JSON serialization, cancellation, and Problem Details mapping.
- Pages never read `.secrets`, acquire tokens directly, or construct API URLs themselves.

## Implemented control-plane API

| Method | Route | Roles |
|---|---|---|
| `GET` | `/health`, `/health/ready` | Anonymous |
| `GET` | `/api/v1/agents` | Administrator, Operator, Auditor, SupportReader |
| `GET` | `/api/v1/agent-identity-blueprints` | Administrator |
| `GET` | `/api/v1/agents/{agentId}` | Administrator, Operator, Auditor, SupportReader |
| `POST` | `/api/v1/agents` | Administrator |
| `GET`, `POST` | `/api/v1/agents/{agentId}/credentials` | Administrator |
| `DELETE` | `/api/v1/agents/{agentId}/credentials/{credentialId}` | Administrator |
| `PATCH` | `/api/v1/agents/{agentId}/features` | Administrator |
| `POST` | `/api/v1/agents/{agentId}:enable` | Administrator, Operator |
| `POST` | `/api/v1/agents/{agentId}:disable` | Administrator, Operator |
| `POST` | `/api/v1/agents/{agentId}:retry-provisioning` | Administrator |
| `DELETE` | `/api/v1/agents/{agentId}` | Administrator |
| `GET` | `/api/v1/agents/{agentId}/audit-events` | Administrator, Auditor |
| `GET` | `/api/v1/agents/{agentId}/provisioning-history` | Administrator, Operator |
| `GET` | `/api/v1/operations/{operationId}` | Administrator, Operator |
| `POST` | `/api/v1/operations/{operationId}:complete-agent365-registration` | Administrator user token with valid `oid` and `access_as_user`; app-only rejected |
| `GET`, `PATCH` | `/api/v1/system/config` | Administrator |

Send `Idempotency-Key` only where the implemented contract accepts it and the latest
ETag as `If-Match` when required. Registration and credential issuance deliberately
do not idempotency-cache their one-time secret response. Never retry a mutation
automatically.

## Unsupported UI data

The API has no control-plane endpoints for:

- listing activity receipts or AI interactions;
- global audit events;
- listing recent/global operations;
- aggregate activity volume or Purview outcomes;
- queue configuration or diagnostic configuration.

Do not invent these APIs. Build dashboards from agent-list data and health probes, keep audit and provisioning agent-scoped, and label unavailable telemetry honestly when it matters.

## Role behavior

- Administrator: all portal pages and actions.
- Operator: dashboard, agents, agent detail, enable/disable, provisioning history, and known operation status.
- Auditor: dashboard, agents, agent detail, and agent-scoped audit events.
- SupportReader: dashboard plus read-only agent list/detail.
- Dashboard, list, and detail pages use the `AllControlPlane` policy; more privileged pages use role-specific authorization and actions use `AuthorizeView`. API enforcement remains authoritative.

## UX requirements

- The registration page generates the required immutable `externalAgentId` as `agent-<guid>`; it is distinct from the gateway record GUID and any IDs later returned by Agent 365.
- Registration ownership defaults from the authenticated Entra `oid` claim and remains editable when another user is accountable; the API separately audits the caller. Fail closed when the signed-in claim is missing or invalid.
- Registration must collect the current blueprint choice: select an existing
  typed reusable Agent ID blueprint from
  `GET /api/v1/agent-identity-blueprints` or create a new reusable blueprint with a
  display name. An ordinary Entra app, including the Gateway API app, is not a valid
  blueprint. Never show or collect an external-runtime managed-identity field: the
  Gateway API key is the ordinary ingress credential and the worker identity is
  trusted deployment configuration.
- Existing-blueprint choice must be a real dropdown backed by the typed catalog,
  sorted for humans and resilient to loading, authenticated error, empty inventory,
  cancellation, and manual refresh. Never convert a Graph failure into an empty list
  or ask users to paste an object ID as the normal path.
- Preserve every typed catalog row, but clearly mark and disable any row whose
  `isAgent365Compatible` is false. Show only the API's safe compatibility issue; do
  not render configured manager application IDs. Report the compatible count, and
  stop submission when none are compatible. The API remains authoritative and
  rechecks on POST, returning HTTP 422
  `AGENT_IDENTITY_BLUEPRINT_INCOMPATIBLE` before persistence or one-time key
  issuance. Do not infer compatibility merely because a row is a typed blueprint.
- When identifiers are shown, label their Graph/resource semantics. Blueprint `id`
  and `appId` are separately named fields but may display the same GUID; an earlier
  2026-08-25 snapshot did so for all 11 rows then present. The current 12-row
  catalog does not extend that point-in-time finding without a fresh property read.
  Do not imply that equality is an error or that it makes the fields
  interchangeable. The current child Agent
  Identity object ID and app/client ID are also the same GUID even though the
  contract retains two names; never relabel them as a Gateway registration ID or
  external ID.
- A successful registration returns `gatewayCredential` once. Stop before automatic
  navigation, show the clear API key, external agent ID, expiration, and exact Bearer
  header, warn that it cannot be retrieved again, and require an explicit Continue
  action. Never put the key in a URL, log, browser storage, audit event, or later
  detail response.
- If that one-time registration/issue response is dismissed or lost, never offer a
  replay/reveal action. Explain that the old clear value is unrecoverable, list only
  safe key metadata, and let an Administrator issue another replacement.
- Agent detail shows credential lifecycle UI only to Administrators: safe metadata
  list, explicit one-time replacement handoff, and a named-key revoke confirmation.
  Never load or render this section for other roles. Revocation is idempotent for an
  already-revoked owned key and must surface
  `AGENT_INGRESS_CREDENTIAL_LAST_USABLE` as guidance to issue/deploy/verify a
  replacement first.
- Registration text fields that must be current at submit bind on `input`, including
  display name, owner object ID, description, and new-blueprint display name. Keep
  ordinary keyboard, paste, autofill, and assistive-technology input synchronized
  before blur; cover this behavior with bUnit rather than relying on browser timing.
- Present provisioning progress as the three product phases **Blueprint**, **Agent
  ID**, and **Agent 365 connection**, while preserving and rendering the exact seven
  ordered API step rows. After five completed rows, workflow v3 is intentionally
  nonterminal at 71% and polling stops with an Administrator action card. Completion
  success resumes polling at 85% for final verification. A display group or action
  must never alter the persisted sequence or imply a Microsoft effect completed.
- The Registry action must be busy/double-invocation guarded and available only when
  the API returns the exact required action. Continuous development may invoke it
  once automatically for an authenticated Administrator; exact-bound deployments
  require confirmation. Surface delegated consent/Conditional Access guidance and
  safe correlation IDs. Never automatically retry a failed action.
- `AgentDetailDto.RetryProvisioning` is the only authority for showing Retry. A
  `Failed` agent/job status alone is not sufficient. Hide or disable Retry and show
  the returned safe reason when `Supported` is false; fail closed when the decision
  is absent. Never automatically retry a mutation.
- Registration and provisioning-retry availability is an API decision. Surface a
  safe `PROVISIONING_DISABLED` response and its correlation ID; do not let the UI
  infer or extend the server's bounded admission window. The deployment-only
  `Provisioning__AdmissionExpiresAtUtc` value is not user data and must not be
  rendered. When authenticated system config returns
  `authorizedRegistrationExternalAgentId`, use that exact server-authorized generated
  ID in the registration form and keep it non-editable; it is public admission/routing
  metadata, not a credential. Do not synthesize a different external ID while an
  exact-bound window is open. In continuous development, use the API-advertised
  continuous mode and do not invent client-side admission. In exact-bound mode,
  registration closes before the separate delegated completion window opens.
- Present Agent 365 observability and the optional Azure Monitor mirror as independent controls. Agent 365 defaults on and Azure Monitor defaults off; do not expose the deprecated `observabilityMode` string as the primary UI model. Gateway/platform diagnostics and Purview remain separate settings. Purview defaults off; if the API returns `UNSUPPORTED_FEATURE_CONFIGURATION`, explain that the deployment-level adapter is not configured and keep the toggle off. Do not imply that signing in as Global Administrator supplies the backend managed identity's Graph permissions or tenant DLP policy.
- Present Prompt Shields as a third independent protection control, not an
  observability destination or Purview mode. Registration loads
  `promptShieldAvailable` from system config, disables an unavailable checkbox, and
  inherits `defaultPromptShieldEnabled`. Settings likewise cannot enable a default
  when the deployment provider is absent. Agent detail displays and updates the
  per-registration value, while the API remains authoritative if deployment state
  changes after the page loads. Explain that protected clients call the prompt
  evaluation endpoint before their model and must return the allowed receipt with
  the exact completed interaction; never imply that the Gateway proxies the model.
- When Purview is enabled for `CreateNew` blueprint registration, require a
  protection-profile choice. List only `Ready` Gateway-managed profiles from
  `GET /api/v1/purview-policy-profiles`, filtered to the selected AuditOnly/Enforce
  mode, or collect a new profile name for the reviewed template. Disable submission
  when `purviewPolicyProvisioningEnabled` is false or the selected catalog cannot be
  verified. Never expose certificate, tenant PowerShell, or raw policy internals.
- Every remote view has loading, empty, error, retry, and cancellation behavior.
- Use explicit UTC/local time labels and accessible status text in addition to color.
- Confirm destructive and state-changing actions.
- Preserve returned correlation IDs in safe error details.
- Never render raw provisioning-worker exception messages; show a fixed operator-safe summary and controlled error code only.
- Poll operation status with bounded intervals and stop on terminal state, navigation, or disposal.
- Responsive behavior and keyboard/focus behavior are completion criteria.

## File ownership for parallel agents

- `admin-ui-platform-builder`: project file, `Program.cs`, authentication, options, API client, Problem Details, configuration.
- `blazor-ui-builder`: `Components/Pages`, `Components/Layout`, `Components/Shared`, and Admin UI static assets.
- `admin-ui-test-writer`: `tests/Gateway.AdminUi.Tests` only.
- `admin-ui-reviewer`: read-only contract, security, accessibility, and regression review.

Agents must not edit another owner's files concurrently without coordination.

## Completion gates

1. Admin UI and test projects restore and build without warnings introduced by the change.
2. Component/API-client/auth tests pass.
3. Full solution builds and existing test suites remain green.
4. Authenticated routes, role-specific actions, Problem Details, polling, and cancellation are exercised.
5. Principal routes are visually inspected at desktop and narrow widths.
6. No secret value or sensitive interaction content appears in source, configuration, logs, or rendered UI.
