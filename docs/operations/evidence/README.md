# Redacted development canary evidence

These tracked, non-secret manifests describe the three retained workflow-v2
dead-letter messages. They contain no clear Gateway key, token,
assertion, authorization header, or raw dependency body.

Current workflow-v3 outcome (2026-08-28): development runs continuous mode and has
two Active registrations, covering both create-new and reuse-existing blueprint
paths. Both Registry records are Available in Microsoft 365 Admin Center. Live
evidence proves bound ingress, Agent 365 OTLP HTTP 200, benign blueprint-scoped
Purview audit, and a synthetic sensitive prompt blocked before observability enqueue.
Queues are v3 `0/0/9`, v2 `0/0/3`, and v1 `0/0/2`; every DLQ remains evidence-only.
See [`continuous-development-proof-20260828.md`](continuous-development-proof-20260828.md)
for safe identifiers and correlations.

`artifacts/deployment-evidence/live-state-20260828-v3-success-final.json` predates
the two continuous registrations. It remains authoritative only for the earlier
bounded canary and its captured recovery state; it is not current SQL job/outbox
evidence. The historical analysis below is retained as chronology and is superseded
for current state.

The pre-canary controller invocation used the first two files with
`ExpectedWorkflowV2DeadLetterCount = 2`. The controller validates GUIDs, strict
booleans, canonical Graph request evidence, cumulative DLQ checkpoints 1 and 2, the
single allowed FIC exception, its blueprint and time correlation, and a fresh live
read of the exact FIC. It never receives, peeks, settles, replays, or purges a
message.

The first manifest proves a GET-only incompatible-blueprint failure. The second
proves exactly one FIC POST followed by delayed visibility and later read-only
reconciliation. The third, `canary-registry-failure-20260826.json`, proves the
confirmed canary GET-reused that FIC, created and verified one child Agent ID,
assigned and verified OtelWrite, then received HTTP 500 from its single Registry
POST without a durable Registry ID. None authorizes retrying its registration.

These are the complete workflow-v2 failure set at the 2026-08-26 checkpoint. After
action-time confirmation, fresh SQL evidence, `WhatIf`, and `Arm`, one form was
submitted. The controller detected DLQ changing and recovered the API closed and
worker inert. The v2 queue is zero active, zero scheduled, and DLQ3; the historical
v1 queue remains `0/0/2` and was not touched.

After MFA and explicit Microsoft 365 Admin Center Refresh, exact searches for
`canary-simple-echo-20260826072647` and child
`8e4859bd-477c-4133-adb1-9030ec13bf5c` each returned 0 of 341 with no visible agent.
This is portal evidence only; it does not prove that the HTTP 500 create made no
backend change. Official CLI 1.1.214 at commit `90c4448` uses a client-generated
Registry ID and known-ID GET, but its delegated AgentX path uses the child ID as
source, a hard-coded AgentX manager, and documents CLI-ID 424. It corroborates
known-ID recovery, not the Gateway's app-only payload semantics.

Historical analysis addendum (not current state and not a change to any evidence manifest): workflow v3
has one submitted registration but is not live-verified end to end. External ID
`agent-v3demo-20260827030009-3c870882`, Gateway registration
`583777f0-c601-4c09-9e28-27dab51ae375`, and operation
`5c4ba41d-24e5-473c-9126-f89f37f7bb18` reached 71% after worker stages 1--5. The
child Agent ID is
`0a2e20d5-6299-4e02-a94e-0c6232a55113`; safe key ID is
`47b13283-5be7-4fc2-88d2-7fef34642214`. No clear key belongs in evidence. One
signed-in Administrator action crossed the Registry create boundary exactly once
and returned an ambiguous outcome before a durable Registry ID was recorded. The
operation is `RequiresManualIntervention` at 71% with
`PROVISIONING_AMBIGUOUS_RESULT`; stage-7 enqueue, data-plane proof, and telemetry
landing do not exist. The action is permanently non-replayable.

Database evidence has distinct purposes:

- `artifacts/deployment-evidence/live-prepare-20260824.json` is immutable,
  hash-validated two-pass prepare provenance. Do not rerun live DDL merely to create
  a newer timestamp.
- `artifacts/deployment-evidence/recovery-baseline-20260826.json` is the immutable
  record of the distinct retained pre-upgrade recovery copy. Reuse it while it
  remains valid; replace it only when stale, invalid, or a real recovery/schema
  reason requires a new baseline.
- `artifacts/deployment-evidence/live-state-20260826-arm-preflight.json` is the
  zero-script live-state proof used for the completed `WhatIf`/`Arm`. Its outbox
  freshness window is short and it must not be reused for a later activation after
  it ages.
- `artifacts/deployment-evidence/live-state-20260826-canary.json`, captured at
  `2026-08-26T07:11:03.2622069Z`, is the zero-script live-state proof used for the
  submitted canary. It proved workflow v2 true, legacy index one, outbox zero, and
  workflow-v2/legacy job counts two plus two.
- `artifacts/deployment-evidence/live-state-20260827-v3-canary-0713.json`, captured
  read-only at `2026-08-27T07:13:51.4766174Z`, is the zero-script proof used for the
  first workflow-v3 no-submission window. It proved outbox zero, active/awaiting v3
  jobs zero, active v2 jobs three, and legacy jobs two.
- `artifacts/deployment-evidence/live-state-20260827-v3-canary-0841.json`, captured
  read-only at `2026-08-27T08:41:38.2934168Z`, proved the same boundaries for two
  further exact-bound no-submission windows.
- `artifacts/deployment-evidence/live-state-20260827-v3-canary-0949.json`, captured
  read-only at `2026-08-27T09:49:10.6200517Z`, is phase `verify`, repeat one, with
  `Scripts: []`. It proves publishable outbox zero, active/awaiting v3 jobs zero,
  active v2 jobs three, and legacy jobs two for a fourth exact-bound window. That
  window closed at operator cutoff `2026-08-27T10:11:26.1449657Z` (API crash
  deadline `2026-08-27T10:13:56.3860457Z`) without submission or any Gateway,
  Microsoft, or data-plane mutation. Final Deactivate left API revision
  `ca-gateway-api-dev--canaryclosed-20260827191353` closed and worker revision
  `ca-gateway-worker-dev-vnet--inert-20260827191353` inert.
- `artifacts/deployment-evidence/live-state-20260827-v3-canary-1158.json`, verified
  at `2026-08-27T11:58:17.1952233Z`, was accepted for the successful exact-bound
  registration Arm. It is historical/stale after registration changed database
  state and must not be reused for delegated completion.
- `artifacts/deployment-evidence/live-state-20260828-v3-completion-20260827223521.json`,
  verified at `2026-08-27T22:35:53.5652147Z`, is the zero-script pre-action proof:
  outbox 0, v3 active 1/awaiting 1, v2 active 3, legacy active 2.
- `artifacts/deployment-evidence/live-state-20260828-v3-post-completion.json`,
  verified at `2026-08-27T23:03:32.2714306Z`, is the zero-script post-action proof:
  outbox 0, v3 active 1/awaiting 0, v2 active 3, legacy active 2. The remaining v3
  active count is the non-completed manual job, not replay authority.

The first `OpenDelegatedCompletion` attempt exposed a controller
`Nullable<Guid>.Value` bug before user action. The corrected controller and
regression coverage passed architecture 105/105 and PowerShell parser 19/19. A
stale-evidence re-Arm was rejected with no mutation; recovery closed API gates and
returned the worker inert. Two later exact-operation completion windows closed
without user action, exact-operation API logs, Registry request, or final enqueue.
The interim closed API revisions were
`ca-gateway-api-dev--delegatedclosed-20260827214632` and
`ca-gateway-api-dev--delegatedclosed-20260827220053`.

That historical Deactivate/Status and post-action verification proved API
`ca-gateway-api-dev--canaryclosed-20260828075643` closed with no admission binding,
and worker `ca-gateway-worker-dev-vnet--inert-20260828080507` inert with Registry
disabled, no migrator settings, and as the sole active worker revision. Digests
remain pinned; v3 is `0/0/0`, retained v2 is `0/0/3`, and historical v1 is `0/0/2`.
That resume path was superseded by the successful, distinct CLI-compatible v3
canary recorded at the top. Never reopen or repeat the historical Registry action.

Never retry or attach the retained v2 canary, issue a second POST for it, or peek/
receive/settle/replay/purge any retained message. Only exact read-only Registry/Admin
Center reconciliation is permitted for that historical request; portal 0/341 is
insufficient. Any new mutation or controlled rollout requires separate scope and fresh safety
evidence. Valid immutable
prepare provenance/recovery baseline need not be regenerated merely because live
state aged.
