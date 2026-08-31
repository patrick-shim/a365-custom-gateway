# A365 Custom Gateway Copilot instructions

Follow the required reading order in `AGENTS.md` before acting. Preserve existing
user changes, respect file ownership, and validate Microsoft contracts against
current official documentation.

## Product invariants

- The Gateway is N:N. One registration binds one generated external ID and Gateway
  key lifecycle to one reusable blueprint and one distinct child Agent ID.
- Workflow v3 keeps seven stable persisted stages on
  `gateway-provisioning-v3`. The worker executes the first five stages, waits at
  71%, never calls Registry, and later performs final verification.
- A signed-in `Gateway.Administrator` completes Registry through the API's user-only
  delegated OBO action. Persist creator-bound planned intent before at most one
  POST; an ambiguous outcome permits exact-ID GET only and never another POST.
- `Active` requires final provider verification. Local state, mocked tests, and
  deployment success are not external-resource proof.
- Data-plane ingress uses a registration-scoped Gateway key, constant-time salted
  verifier comparison, and an `externalAgentId` cross-check. Clear keys are issued
  once and never replayed.

## Optional protections

Prompt Shields and Purview are optional runtime features, not bootstrap completion
requirements. When selected they fail closed.

Purview policy scopes remain independent:

- Know Your Data: fixed Group `ee1680d0-702f-4090-b26c-c49091e86531`;
- DLP: selected blueprint application ID as an Individual location;
- both: Application enforcement plane.

Never merge blueprint IDs into the Know Your Data Group. Policy readback does not
prove propagation or a runtime verdict.

## Bootstrap and security

The root `gateway` and `gateway.cmd` launchers call the supported resumable
`bootstrap/bootstrap.ps1` engine. Preserve ignored `.bootstrap/` state; it contains
safe identifiers only. Bootstrap has no destroy mode and initializes SQL only when
the database has zero user tables.

Never read, render, print, log, alter, copy, transmit, or commit `.secret` or
`.secrets` values, clear Gateway keys, credentials, tokens, assertions,
authorization headers, certificate material, prompts, responses, or provider
bodies. Use private inputs only through the documented non-echoing path.

Run the smallest affected tests first, then the broader Release, source, Bicep,
formatting, documentation-link, and secret-path gates required by `AGENTS.md`.
