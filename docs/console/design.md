# A365 Gateway Console — design system & frontend direction

Authoritative design and engineering direction for the Gateway's user interface.
This supersedes the Blazor Admin UI. New UI work follows this document.

> TL;DR — We are moving **entirely off Razor/Blazor** to a modern **React + TypeScript**
> single‑page app on the **existing .NET REST API**. The UI is organised by **persona**,
> every page does **one job**, copy is **plain and short**, and interactions are **instant**.

---

## 1. Decision and scope

| Area | Decision | Why |
|---|---|---|
| **Frontend** | **Replace Blazor with a React + TypeScript SPA.** Retire `Gateway.AdminUi` (Blazor Server) and later `Gateway.Setup`. | Blazor Server round‑trips every click over SignalR → visibly laggy. A SPA is instant, reactive, modern and flexible. |
| **Backend** | **Keep the .NET REST API, worker and Windows Purview executor.** | The API is already fast and secure; the Purview executor *must* be Windows + PowerShell (`Connect-IPPSSession`). A Node rewrite adds months of risk for no user benefit. |
| **Contract** | The SPA consumes `/api/v1/*` with an MSAL-acquired delegated bearer token. | The API is the authoritative contract; an OIDC browser session alone is not API authentication. |

**No more Razor.** Blazor components are frozen; all new UI is React. The Blazor
Admin UI is decommissioned at the end of the migration (§8).

---

## 2. Personas — the UI is organised around three people

| Persona | Does | Rhythm | Zone |
|---|---|---|---|
| **Deployer** | Bootstraps the Gateway, picks region/SKUs/capabilities, clears one‑time admin actions, checks health, upgrades. | Once, then rare | **Platform** |
| **Operator** | Registers agents (blueprint → Agent ID), issues the one‑time key, enable/disable, rotate key, flips **Prompt Shields** per agent, watches activity. | Daily | **Agents** |
| **Policy manager** | Connects Purview, reviews classifiers (SITs), sets **DLP** per blueprint, tests behaviour. | Setup, then occasional | **Data protection** |

A fourth actor — the **external developer** — never uses this UI. They receive an
external ID + one‑time key and call the REST API. Their surface is the API + sample client.

---

## 3. Information architecture

```
Home  ── "Needs attention" across all zones, routes you to the right place

Agents            (Operator)
  ├─ Agents list
  ├─ Register agent        (3 steps: Name → Blueprint → Key)
  └─ Agent detail          (tabs: Prompt Shields · Identity · API key · Activity)

Data protection   (Policy manager)
  ├─ Connection            (one‑time Purview setup + re‑check)
  ├─ Classifiers (SIT)
  └─ Policies (DLP)        (per‑blueprint editor, modes, behaviour tests)

Platform          (Deployer)
  ├─ Health
  ├─ Defaults              (incl. Prompt Shields default for new agents)
  └─ Access (roles)
```

### The separation rule (non‑negotiable)

| Control | Owner | Lives on | Shape |
|---|---|---|---|
| **Prompt Shields** | Operator | the **Agent** | one On/Off toggle |
| **DLP / SITs** | Policy manager | **Data protection** | a real policy editor |
| **Defaults** | Deployer | **Platform** | set once |

Prompt Shields and DLP **never share a screen**. Registration **never** shows
protection knobs — it picks a blueprint and returns a key.

---

## 4. Design directives — sleek, modern, reactive, flexible, intuitive

These are rules, not aspirations. A review may reject UI that breaks them.

**Plain and short**
- One job per page. If a page answers two questions, split it.
- **Max one line** of helper text under any control. No paragraphs. No manuals.
- Lead with the **action**, not the explanation.
- Plain words: *Needs setup, On/Off, Running, Register once*. Never show a raw
  code (`PURVIEW_CONNECTION_PROVIDER_UNVERIFIED`) as the headline — demote it to a
  small "Details" line.

**Reactive / instant**
- No full‑page blocking spinners where a section spinner or skeleton will do.
- Show pending feedback immediately. Never present a protection change as effective
  until server readback confirms it; do not optimistically claim enforcement.
- Navigation is instant (client‑side routing). Data is cached and revalidated
  (TanStack Query), never re‑fetched on every nav.
- Async status is announced politely (`aria-live`) and shown inline, not in modals.

**Sleek / modern**
- Fluent UI v9 design tokens; generous whitespace; one accent; restrained colour.
- Consistent components (status pills, copyable commands, page headers, cards).
- Motion is subtle and respects `prefers-reduced-motion`.

**Flexible**
- Responsive down to tablet; the shell collapses the nav.
- Light / dark / high‑contrast via Fluent themes — no hard‑coded colours.
- Role‑aware: zones and actions render per the signed‑in role; read‑only is a
  first‑class state, not a dead end.

**Intuitive**
- **Progressive disclosure:** show the next action; hide technical detail behind a
  "Details" affordance.
- A single **"Needs attention"** home surfaces cross‑zone work with a direct link.
- Dangerous or one‑way actions (rotate key, enforce policy) confirm in plain words.

---

## 5. Technology stack

| Concern | Choice | Notes |
|---|---|---|
| Language | **TypeScript** (strict) | `noUnusedLocals`, `noUnusedParameters`, strict null checks |
| UI library | **React 18** | function components + hooks only |
| Build/dev | **Vite 5** | fast HMR, static output |
| Design system | **Fluent UI React v9** (`@fluentui/react-components`) | Microsoft‑native look, tokens, themes, a11y |
| Server state | **TanStack Query v5** | caching, revalidation, optimistic updates |
| Routing | **React Router v6** | client-side routes with a recoverable route error boundary |
| Auth | **MSAL React** (Entra OIDC) | same identity model as today's Blazor OIDC |
| Unit/component tests | **Vitest + Testing Library** | fast, jsdom |
| E2E | **Playwright** | live acceptance journeys; not yet a committed CI suite |
| Lint/format | **ESLint + Prettier** | planned, not a current CI gate |
| Packaging | static assets in a small container (nginx) or served by the API host | replaces the Blazor UI image |

Design‑system note: Fluent v9 is the pragmatic, Microsoft‑consistent default. If a
more bespoke visual identity is ever required, the escape hatch is Tailwind + Radix
primitives — but **not mixed** with Fluent in the same surface.

---

## 6. Component and content standards

- **StatusPill** — maps status → plain words + a tone colour. One source of truth.
- **CopyableCommand** — read-only value + Copy button, with a visible clipboard
  error. One-time keys must not enter query caches or persistent browser storage.
- **PageHeader** — title + one‑line subtitle + optional primary action/status.
- **AppShell** — persona‑zoned left nav, top bar with signed‑in identity, content column.
- **Failure codes** — always translated to a human sentence; the raw code appears
  only under "Details" for support.

Current implementation lives in [`web/console/src`](../../web/console/src).

---

## 7. Accessibility & internationalisation

- Target **WCAG 2.1 AA**. Full keyboard operability; visible focus; logical tab order.
- Async regions use `role="status"` / `aria-live="polite"`.
- Respect `prefers-reduced-motion` and `prefers-color-scheme`.
- All copy is centralised and translatable; no concatenated sentences that break i18n.

---

## 8. Implementation and acceptance boundaries

The early prototype was deployed with guessed contracts and demo actions. Its
build and sign-in checks did **not** establish usable navigation or human
acceptance. The corrected client validates the actual API envelopes and has
regression tests for navigation, registration, errors, and mutations.

| Surface | Current implementation |
|---|---|
| Navigation | React routes; loading/error/empty states; render failures preserve the shell |
| Agents | Server-owned registration defaults without a selector; paginated list/detail, one-time keys, replacement/revocation, per-agent Prompt Shields, confirmed Registry completion and operation progress |
| Connection | Explicitly reviewed Gateway verification, operation polling and safe failure details; Connected requires independent provider readback |
| Classifiers | Current inventory and expiration; refresh requires successful provider verification |
| Policies | Read-only saved policy list; editor and behavior tests remain unfinished |
| Platform | Actual API health/capabilities and persisted Prompt Shields defaults; no fabricated worker health |
| Packaging | Separate nginx Console container; bootstrap integration and Blazor retirement remain unfinished |

The persona zones do not alter authorization: the backend currently requires
Administrator for registration, credential actions, and protection mutations.
Registry completion additionally requires a delegated administrator. Role-aware
navigation remains migration work; client controls never grant API authority.

The Console requests `verificationMode: "Gateway"` at connection review and start.
It must verify the returned mode and `VerifyPurviewTenantConnection` operation
type before confirmation. That distinct durable type and its mode-bound payload
hash authorize the existing independent verifier without claiming interactive
evidence existed. The worker retains tenant/actor and exact installed
application/principal/Key Vault/certificate checks, reads the provider twice, and
only marks Connected after final authoritative readback. A fresh reviewed check
can supersede an expired companion handoff, not an in-progress verification.

Omitting the mode preserves the legacy companion workflow and its original
review/accepted-request hashes. No database migration or executor package change
is required. API and worker must be upgraded together before the new Console is
enabled; old replicas cannot consume the new operation type. See the
[cutover notes](../../web/console/README.md#api-and-worker-cutover).

Registration defaults are read-only deployment capabilities, not a browser
environment choice. Production is the standard contract default. This installed
DirectRegistryPreview implementation explicitly advertises Development with a
reason because its provider guard rejects other environments. The Console blocks
registration if the capability data is unavailable; existing agent environments
are never relabeled. Registry completion is a confirmed, bodyless delegated API
action; HTTP 200 means verification was queued, not that the agent is Active.

Acceptance requires the exact deployed image to pass authenticated menu-click,
registration, and mutation journeys. Connection verification, policy readiness,
runtime enforcement, downstream delivery, and human approval are separate
outcomes; none may be inferred from HTTP 200/202 or a successful build.

---

## 9. Authoritative backend contracts

Use the existing `Gateway.Contracts` DTOs and controller routes. Validate payloads
at the client boundary. Unknown response shapes are errors, not empty success.

| Need | Endpoint | Status |
|---|---|---|
| Agents list / detail | `GET /api/v1/agents`, `GET /api/v1/agents/{id}` | exists |
| Per-agent Prompt Shields | `PATCH /api/v1/agents/{id}/features` | `If-Match` and idempotency required |
| Register agent | `POST /api/v1/agents` (+ key issue) | exists |
| Registration defaults | `GET /api/v1/system/config` | `registrationDefaults.environment` and server-owned `reason`; no selector |
| Registry progress | `GET /api/v1/operations/{id}` | ID from agent detail `provisioning.operationId`; required action, completion availability, polling recommendation |
| Registry completion | `POST /api/v1/operations/{id}:complete-agent365-registration` | No body; delegated administrator, deployment gate, exact-ID recovery; follow verification readback |
| Blueprints | `GET /api/v1/agent-identity-blueprints` | `{ items: [...] }`; object/client IDs are distinct |
| Purview connection | `GET /api/v1/protection/purview/connection` | `{ connection: object or null }` |
| Connection check | `connection-operations:review`, `operation-reviews:confirm`, `connection-operations` under `/api/v1/protection/` (connection routes under `purview/`) | `verificationMode: "Gateway"` on review/start; verify mode and operation type, never fall back to companion |
| Operation readback | `GET /api/v1/protection/operations/{id}` | `{ operation: ... }` |
| Classifiers (SIT) | `GET /api/v1/protection/purview/sensitive-information-types` | Inventory metadata plus `items`; entries use `exactName` |
| DLP profiles | `GET /api/v1/protection/purview/dlp-profiles` | `{ items: [...] }`; readiness is an object |
| Platform | `GET /health/checks`, `GET /api/v1/protection/capabilities`, `GET/PATCH /api/v1/system/config` | Health, capabilities, and defaults are distinct |

The `:enable` and `:disable` routes change agent lifecycle, never Prompt Shields.
A generic `PURVIEW_CONNECTION_PROVIDER_UNVERIFIED` failure does not prove that a
Security & Compliance service-principal reference is missing. Do not prescribe
provider mutations without specific evidence.

---

## 10. Why this fixes the complaints

- *"Fails with zero explanation"* -> failures stay visible with a plain message,
  operation status, and safe code/reference under Details.
- *"Download a script and paste strings back"* -> reviewed Gateway-owned
  verification queues the existing provider reader without companion evidence.
  Actual provider failure remains visible; neither a queued check nor a passing
  isolated test establishes live access.
- *"Why choose Development/Test/Production?"* -> the server supplies the default
  and the preview exception reason. There is no unnecessary environment selector.
- *"Every menu goes black"* -> validate response wrappers, test actual menu clicks,
  and keep navigation outside the route error boundary. Never mask API failures
  with demo data or success-shaped defaults.
- *"Cluttered, mixes Prompt Shields and registration"* → one job per page; the
  separation rule (§3) keeps Prompt Shields, DLP and defaults apart.
- *"Not reactive / modern / slow"* → SPA with client routing, caching and optimistic
  updates; no Blazor Server round‑trips.

See the running app and how to build it in [`web/console/README.md`](../../web/console/README.md).
