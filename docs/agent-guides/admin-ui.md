# Admin UI contributor guide

Read the current [implementation status](../implementation-status.md) and
[deployment status](../operations/development-deployment-status.md) before changing
the portal. The API contract and server-advertised capability flags are
authoritative.

## Purpose

The Blazor Admin UI helps authorized tenant users configure and operate the Gateway.
It never bypasses API authorization, performs provider work directly, or exposes
secret/content material.

## Roles

The portal recognizes `Gateway.Administrator`, `Gateway.Operator`,
`Gateway.Auditor`, and `Gateway.SupportReader`. Route visibility and disabled states
improve usability; every API route independently validates role, user, tenant,
audience, and scope.

An authenticated user without an assigned Gateway role must reach the dedicated
access-denied route, not the application not-found page.

## Current routes

| Area | Typical route | Purpose |
|---|---|---|
| Setup Center | `/setup`, `/getting-started` | Deployment checks and first-use guidance |
| Overview | `/` | Health, inventory, and safe operational summary |
| Agents | `/agents` | Registration inventory and filtering |
| Registration | `/agents/register` | Blueprint, observability, and optional-protection choices |
| Agent detail | `/agents/{id}` | Lifecycle, credentials, operations, safe evidence |
| Operation | `/operations/{id}` | Persisted seven-stage progress and Administrator handoff |
| Access denied | `/access-denied` | Authenticated user lacks a Gateway role |

## Registration experience

The UI loads the typed blueprint catalog and server configuration. It disables
incompatible blueprints and unavailable optional features, but the API rechecks all
choices before persistence or key issuance.

For a new blueprint, Purview profile selection is optional. Show only Ready profiles
or the reviewed create-profile path when the server advertises that capability. Do
not display policy internals, certificate information, or provider response bodies.

The successful registration response can contain a one-time Gateway key. Render it
only in the immediate success state with copy/download guidance that avoids browser
storage. Never re-render it from logs, history, or server state.

## Operation experience

Show persisted stage name, percentage, status, safe timestamps, correlation ID, and
the exact next user action. At the Administrator handoff, invoke only the authenticated
API completion endpoint. Claims challenges must preserve the server response and
return the user through the supported sign-in flow.

Do not infer Microsoft-side success from percentage, a prior stage, or a local UI
event. `Active` is Gateway-reported state after final verification.

## Optional protections

- Prompt Shields is pre-model. Explain that the external client must evaluate before
  calling its model and send the single-use receipt with the interaction.
- Purview is per registration. The UI chooses a profile/mode; it does not author
  policies directly.
- Know Your Data collection is tenant-wide fixed Group scope; DLP is blueprint
  Individual scope. Do not describe them as one blueprint-scoped pair.
- Offline `downloadText` is not response-side inline blocking.

## Error and empty states

Use RFC 9457 information supplied by `IGatewayApiClient`. Render user-safe title,
detail, retry guidance, and correlation ID. Never show dependency bodies,
authorization headers, tokens, prompts, responses, clear Gateway keys, or stack
traces.

Distinguish loading, empty, restricted, unavailable, and failed states. A 404 inside
the portal and an authenticated role denial are different experiences.

## File ownership

- Pages: `src/Gateway.AdminUi/Components/Pages`
- Layout: `src/Gateway.AdminUi/Components/Layout`
- Shared components: `src/Gateway.AdminUi/Components/Shared`
- API/auth/config: `src/Gateway.AdminUi/Services`, `Models`, `Options`,
  `Authentication`
- Tests: `tests/Gateway.AdminUi.Tests`

Use a code-behind partial only when it materially improves a large component.

## Verification

1. Run the focused bUnit tests for changed components/services.
2. Run the full Admin UI test project.
3. Run a Release build and formatting check.
4. Inspect changed routes at desktop and narrow widths.
5. Verify Administrator and non-Administrator behavior.
6. Verify errors/access denial never render as not-found and never expose sensitive
   data.
7. Update public documentation only when the user workflow changed.

Automated UI tests must not mutate a live tenant.
