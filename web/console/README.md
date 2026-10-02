# A365 Gateway Console

React and TypeScript SPA using the existing .NET Gateway REST API.
It is the replacement direction for the Blazor Admin UI, not yet full feature
parity. See the [Console design](../../docs/console/design.md).

## Run locally against an API

Use the existing Entra SPA registration with a registered local redirect URI.
Only public identifiers belong in these settings; never supply a client secret.

```powershell
Set-Location .\web\console
npm ci
$env:VITE_CLIENT_ID = "<SPA application ID>"
$env:VITE_TENANT_ID = "<tenant ID>"
$env:VITE_API_SCOPE = "api://<Gateway identifier>/access_as_user"
$env:GATEWAY_API_BASE_URL = "https://<Gateway API host>"
npm run dev
```

The container writes public settings into `config.js` from `CONSOLE_CLIENT_ID`,
`CONSOLE_TENANT_ID`, and `CONSOLE_API_SCOPE`. Configure the same-origin proxy with
`GATEWAY_API_ORIGIN` and `GATEWAY_API_HOST`. Sign-in uses MSAL authorization code
with PKCE, then a delegated bearer token for API calls.

Missing configuration shows an error. There is no automatic mock/demo mode,
including when the old `CONSOLE_USE_MOCK` setting is true. Test fixtures are
isolated to the regression suite.

## Check and build

```powershell
npm test
npm run typecheck
npm run build
```

The Docker build also runs the regression suite before bundling. Build with this
directory as the Docker context. `SOURCE_REVISION` can label the immutable image
with its source commit. Publish the image to the existing registry and deploy by
digest; do not recreate the Gateway or its Entra registrations for a UI update.

Azure Container Apps requires the Linux x64 runtime image, even when developing
on Windows ARM. The Node build stage runs natively; its output is static assets.

```powershell
docker buildx build --platform linux/amd64 --provenance=false --load `
  --build-arg SOURCE_REVISION=<commit> --tag <registry>/gateway-console:<release> .
docker image inspect <registry>/gateway-console:<release> --format '{{.Os}}/{{.Architecture}}'
```

Require `linux/amd64` before publishing. An ARM64 image can fail activation with
an image-pull error; changing registry permissions does not repair its platform.

## Working surfaces and boundaries

- All routes keep navigation visible during loading, API failures, and contained
  render failures. RFC 9457 errors retain their support code and correlation ID.
- Agents support paginated reads, real registration using an existing compatible
  blueprint or a new blueprint, one-time key handoff, replacement key issuance,
  and explicit revocation.
- Registration returning HTTP 202 means accepted, not provisioned. Lost responses
  are checked by exact external ID instead of automatically replaying creation.
- Registration has no environment selector. `GET /api/v1/system/config` supplies
  read-only `registrationDefaults.environment` and `reason`. Production is the
  standard contract default; the installed DirectRegistryPreview provider
  explicitly advertises Development and its beta-registry restriction. Missing
  defaults, a missing non-production reason, or a closed provisioning gate prevent
  submission. Existing agents retain their recorded environment.
- Agent detail uses `provisioning.operationId` to read the actual provisioning
  operation. A Registry action appears only when that operation advertises
  `CompleteAgent365Registration` and completion availability. Explicit confirmation
  sends a bodyless POST to the existing delegated-administrator endpoint. The API
  acquires the current user's Graph OBO token before persisting create intent;
  uncertain attempts remain exact-ID reconciliation, never a new registration.
  HTTP 200 queues verification, not an Active result. Operation progress and agent
  readback remain authoritative, including failures and closed gates.
- Prompt Shields uses `PATCH /agents/{id}/features`, including matching
  `If-Match` and idempotency headers/body fields. It never calls the agent
  enable/disable endpoints. Requested and effective states are distinct.
- Purview Connection uses the existing review, explicit confirmation, start,
  and operation-readback protocol with explicit `verificationMode: "Gateway"`.
  It verifies both that mode and `VerifyPurviewTenantConnection` in the review;
  an older companion-only API is a visible error, never a fallback. Confirmation
  queues the independent verifier using the installed application, service
  principal, Key Vault and certificate binding. Two exact provider reads and the
  final check are required before Connected. No local script or pasted evidence
  is involved, and no provider permissions are granted or changed.
- A fresh Gateway check can replace an expired `AwaitingAdministrator` handoff
  after review against the current row version. The existing tenant/actor binding
  remains enforced; another actor cannot silently take over a connection.
  Starting a check invalidates previous verified access until fresh readback.
  Operation links survive reloads; an uncertain start is read back using the
  reviewed operation ID, not automatically posted again. Failure details retain
  the safe step, code and support reference without guessing the provider cause.
- Classifiers use the actual inventory envelope and expiration metadata. Reload
  reads the saved inventory; inventory refresh requires a successful Gateway
  provider verification.
- Policies is currently **read-only**. Policy editing, behavior tests, and
  runtime enforcement management are not yet implemented in the React Console.
- Platform reports API health, actual capabilities, and persisted Prompt Shields
  defaults. API health is not worker health; installation is not enforcement.
- Agent setup failures retain the API's provisioning step and failure detail.
  The provider's `PROVISIONING_PREVIEW_DISABLED` guard is unchanged. Feature edits
  are available only in the API-supported Active and Disabled lifecycle states.

One-time Gateway keys and review/confirmation values stay in component memory,
not local/session storage or the shared query cache. Leaving their page hides
them. Replacing a key does not implicitly revoke an old key.

Registry Conditional Access challenges are decoded from `WWW-Authenticate` and
used only in an explicit MSAL interaction against the configured Gateway API
scopes. The Console does not follow an authority URL from a response or request
Graph permissions for the SPA. A consent challenge identifies the Gateway API's
required delegated scopes for an administrator; sign-in alone is not admin
consent. No mutation is automatically replayed after sign-in. Claims recovery
context stays in memory; token storage remains owned by the existing MSAL cache.

## API and worker cutover

Deploy the matching API and provisioning worker before enabling this Console's
new workflows. Retire old API/worker replicas before accepting new Gateway-mode
operations: old binaries do not understand the new persisted operation type.
The queue name, workflow version, step/attempt bindings, and database schema are
unchanged. `VerifyPurviewTenantConnection` is a new string enum value, and the
existing bounded `AuthorityKind` temporarily binds pending verification to its
operation ID. No migration, executor script/package change, role grant, or
bootstrap/maintenance-state mutation is required by this source change.

Old clients omitting `verificationMode` retain the companion review/start/complete
flow and its original payload/idempotency hashes. New Gateway reviews have a
separate mode-bound hash and cannot be confirmed or replayed as companion mode
(or vice versa). Both paths retain consumed confirmations, tenant/actor checks,
row versions, audits and exact provider verification.

Tests with isolated providers establish workflow behavior, not live Purview
access or Registry consent. The deployment owner must independently verify the
installed provider, delegated authorization and final readback. A generic
`PURVIEW_CONNECTION_PROVIDER_UNVERIFIED` code is not a diagnosis and never
justifies recreating a provider reference or widening permissions.

The legacy Admin UI remains deployed. This Console is not yet part of the
canonical bootstrap workflow. A successful build or smoke test is not human
acceptance of the full product.
