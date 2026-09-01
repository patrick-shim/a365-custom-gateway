---
name: a365-admin-ui
description: Build, extend, test, or review the A365 Gateway Blazor Admin UI against its implemented Azure API and Entra role model.
---

# A365 Admin UI

Follow the binding **Required reading** order in `AGENTS.md` completely before
acting; do not replace or reorder it here. For this workstream,
`docs/agent-guides/admin-ui.md` is the relevant guide. The API contract,
server-advertised capabilities, roles, routes, and shared guide are authoritative.

For foundation work, own authentication, options, services, and API transport. For
page work, implement a vertical route with the shared client/components. For review,
remain read-only and check contract fidelity, role behavior, sensitive-data
exposure, loading/error states, accessibility, and responsive layout.

The current workflow waits after five worker stages and exposes
`requiredAction=CompleteAgent365Registration`. Only a signed-in
`Gateway.Administrator` invokes the typed completion endpoint. Preserve
consent/Conditional Access guidance, claims challenges, and safe correlations.
Never ask users to paste a token or replay an old operation.

An authenticated user without a Gateway role must reach the access-denied experience,
not a not-found page. UI role checks improve usability; the API remains authoritative.

For Purview-enabled new blueprints, use the typed profile catalog and require a Ready
compatible profile or reviewed new-profile request. Do not expose policy internals,
PowerShell/certificate material, or an unsupported submit path. Keep tenant-wide
Know Your Data Group scope distinct from blueprint Individual DLP.

Treat Prompt Shields as an independent per-registration pre-model control. Explain
evaluate, allow receipt, model call, and receipt-bound interaction without claiming
the Gateway proxies the external model.

Never read or expose `.secret`/`.secrets`, clear Gateway keys, credentials,
tokens, prompts, responses, or provider bodies. Run focused bUnit tests, the full UI
test project, Release/format checks, and desktop/narrow visual inspection.
