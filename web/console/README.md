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

## Working surfaces and boundaries

- All routes keep navigation visible during loading, API failures, and contained
  render failures. RFC 9457 errors retain their support code and correlation ID.
- Agents support paginated reads, real registration using an existing compatible
  blueprint or a new blueprint, one-time key handoff, replacement key issuance,
  and explicit revocation.
- Registration returning HTTP 202 means accepted, not provisioned. Lost responses
  are checked by exact external ID instead of automatically replaying creation.
- Prompt Shields uses `PATCH /agents/{id}/features`, including matching
  `If-Match` and idempotency headers/body fields. It never calls the agent
  enable/disable endpoints. Requested and effective states are distinct.
- Purview Connection uses the existing review, explicit confirmation, start,
  and operation-readback protocol. It does not invent a `connection:recheck`
  endpoint, ask for scripts, or infer a missing provider reference from a generic
  verification failure. Operation links survive reloads.
- Classifiers use the actual inventory envelope and expiration metadata. Reload
  reads the saved inventory; a connection check refreshes it from Purview.
- Policies is currently **read-only**. Policy editing, behavior tests, and
  complete Registry handoff are not yet implemented in the React Console.
- Platform reports API health, actual capabilities, and persisted Prompt Shields
  defaults. API health is not worker health; installation is not enforcement.

One-time Gateway keys and review/confirmation values stay in component memory,
not local/session storage or the shared query cache. Leaving their page hides
them. Replacing a key does not implicitly revoke an old key.

The legacy Admin UI remains deployed. This Console is not yet part of the
canonical bootstrap workflow. A successful build or smoke test is not human
acceptance of the full product.
