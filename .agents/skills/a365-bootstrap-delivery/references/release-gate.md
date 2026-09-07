# End-to-end bootstrap release gate

The supported outcome is: a public user clones `a365-custom-gateway`, runs the root launcher, completes the local UI configuration, deploys to a clean authorized subscription, opens the Admin UI, and verifies the Gateway's enabled functions.

## Gate evidence

Apply the [end-to-end execution contract](../../../../docs/agent-guides/end-to-end-execution.md).
The user's selected Full evaluation matrix includes Windows execution, two
registrations, independent Agent 365 landing and Prompt Shields/DLP allow/block on
the currently approved targets and repeated scratch runs. Core bootstrap ending at Verify
does not end that delivery. Progress automatically within existing authority;
preserve explicit stops and record unavailable approval responses as NoResponse.
Source-subtask completion and host turn closure never close the product gate.

### Plan

- user journey and supported commands are explicit
- affected source/state generations and recovery boundary are identified
- live mutation authority and target are recorded
- regression test is defined before the correction

### Build

- release configuration builds with zero errors
- every bootstrap Bicep entry compiles
- generated or packaged public checkout contains every required file

### OfflineValidate

- relevant regression tests pass
- complete bootstrap test suite passes
- source/configuration fingerprint and resume-state fixtures pass
- a clean exported checkout passes repository-layout and launcher smoke tests
- Windows command parsing/path/tool discovery is tested on Windows, not inferred from macOS

### Deploy

- authenticated Plan/What-If passes against the exact authorized tenant/subscription
- accepted plan fingerprint is recorded
- Apply/Resume completes without resetting valid state
- Azure/Entra/Graph/SQL/Purview mutations remain within recorded authorization

### LiveValidate

- `gateway verify` passes
- Admin UI sign-in and primary routes pass in a real browser
- the implemented protection source is deployed cleanly and verifies two compatible
  blueprints, created or reused as authorized, with one delegated-Administrator-created
  external registration for each
- actual Registry completion remains a signed-in `Gateway.Administrator` user-only
  OBO action for each registration
- observability, enabled per-agent Prompt Shields, and blueprint-scoped DLP are
  validated with approved synthetic input
- queue, outbox, health, and immutable image evidence are recorded

The implemented source cannot satisfy Deploy or LiveValidate until a fresh,
exactly authorized deployment proves it. Bootstrap presets prepare capabilities
only and never select a SIT or author policy. Gateway Settings owns
SIT/KYD/DLP/readiness and per-registration controls on dedicated
`gateway-protection-admin-v1`. Companion evidence remains non-authoritative until
exact capability-bound provider verification; the immutable Admin UI image supplies
the downloadable Windows companion without executing it. `Ready` requires capability,
readback, propagation, token roles, and runtime allow/block evidence. Purview remains
fail closed with fixed KYD Group versus blueprint Individual DLP scopes on the
Application plane. Live validation requires fresh exact-target authority.

### UpdateCheckpoint

- implementation and deployment status record exact current evidence
- public root and bootstrap READMEs match the tested journey
- stale troubleshooting narrative is not promoted as product guidance
- the release commit and remote branch are identified
- Copilot, Codex, Claude, role specs, skill adapters and communication follow
  `docs/agent-guides/model-handoff.md`; current live facts remain centralized
- all required implementation is committed on canonical `main`, with no remaining
  source worktree or ignored-only implementation needed for the handoff

### Complete

- an independent review finds no missing gate evidence
- `CURRENT.json` has no blockers and names the next product objective
- the session is closed; later work starts a new session

## Invalidation

A source change invalidates Build and all later gates. A configuration or plan change invalidates Plan and all later gates. A deployment-only external change invalidates Deploy and LiveValidate. Documentation-only corrections invalidate UpdateCheckpoint and Complete.

Never reuse a passed gate merely because its command succeeded in a different source generation, operating system, subscription, or deployment state.
