# A365 Custom Gateway Copilot instructions

Follow the required reading order in `AGENTS.md` before acting. Preserve existing
user changes, respect file ownership, and validate Microsoft contracts against
current official documentation.

## After a fetch, pull, or fresh clone

Follow the exact required reading order in `AGENTS.md`. That sequence includes
`docs/implementation-status.md`, then `docs/agent-continuation.md`, then
`CLAUDE.md` and the relevant workstream guide. Before any live or deployment
action, also read `docs/operations/development-deployment-status.md` and the
applicable runbook. Do not reconstruct current work from chat transcripts or
project chronology.

Git transfers the tracked source, tests, instructions, and continuation checkpoint.
It does not transfer `.agent-runtime/`, retained legacy `.agents/runtime/`,
`.bootstrap/`, `bootstrap/config.json`, `.secret`, or `.secrets`. When the current
local delivery ledger is absent, initialize a new one from the tracked continuation
checkpoint and record the checked-out HEAD. A new clone can continue source work,
but it cannot Resume an existing deployment without that deployment's original
ignored state and renewed operator authority. Obey the live-action boundary in the
current `docs/agent-continuation.md`; a tracked checkpoint never grants live
authority by itself.

For bootstrap implementation, recovery, validation, or handoff work, read
`.agents/skills/a365-bootstrap-delivery/SKILL.md` and use its durable ledger
protocol before taking a task action.

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
