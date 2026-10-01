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
| **Contract** | The SPA consumes `/api/v1/*` directly with the browser's Entra (OIDC) session. | Clean separation; the API is the stable contract. |

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
- **Optimistic updates** for toggles and quick actions; reconcile on response.
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
| Routing | **React Router v6** | client‑side, lazy routes |
| Auth | **MSAL React** (Entra OIDC) | same identity model as today's Blazor OIDC |
| Unit/component tests | **Vitest + Testing Library** | fast, jsdom |
| E2E | **Playwright** | smoke + hero‑flow journeys |
| Lint/format | **ESLint + Prettier** | CI gate |
| Packaging | static assets in a small container (nginx) or served by the API host | replaces the Blazor UI image |

Design‑system note: Fluent v9 is the pragmatic, Microsoft‑consistent default. If a
more bespoke visual identity is ever required, the escape hatch is Tailwind + Radix
primitives — but **not mixed** with Fluent in the same surface.

---

## 6. Component and content standards

- **StatusPill** — maps status → plain words + a tone colour. One source of truth.
- **CopyableCommand** — read‑only command + Copy button; used for every operator
  command (e.g. `New-ServicePrincipal`, curl samples). Never make a user retype.
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

## 8. Migration plan (retire Blazor)

| Phase | Deliverable | State |
|---|---|---|
| **1** | React foundation: IA, three zones, Home, Agents + per‑agent Prompt Shields, Purview Connection remediation. Runs on mock data mirroring `gw40397-dev`. Builds green, 0 console errors. | **Done** |
| **2** | Real API: add the UI‑shaped endpoints (§9), wire MSAL/OIDC, replace mock with live client. | Next |
| **3** | DLP policy editor + behaviour tests + classifier refresh; Register wizard issues real keys. | |
| **4** | Deployable container for the SPA; cut Admin UI over; **remove `Gateway.AdminUi`**. | |
| **5** | Re‑platform `Gateway.Setup` (installer UI) to React; remove it from Blazor. | |

"Done" at each phase means: builds, type‑checks, unit + E2E green, and the hero
flows verified in a browser.

---

## 9. Backend contract the Console needs

Most already exist in `Gateway.Api` (`/api/v1/*`). A few UI‑shaped read models are
added in phase 2 so the SPA doesn't fan out N calls per screen.

| Need | Endpoint | Status |
|---|---|---|
| Agents list / detail | `GET /api/v1/agents`, `GET /api/v1/agents/{id}` | exists |
| Per‑agent Prompt Shields | `POST /api/v1/agents/{id}:enable` / `:disable` (prompt‑shield variant) | adjust |
| Register agent | `POST /api/v1/agents` (+ key issue) | exists |
| Blueprints | `GET /api/v1/agent-identity-blueprints` | exists |
| Purview connection (UI read model) | `GET /api/v1/protection/purview/connection` | **new (phase 2)** |
| Re‑check connection | `POST /api/v1/protection/purview/connection:recheck` | **new (phase 2)** |
| Classifiers (SIT) | `GET /api/v1/protection/purview/sensitive-information-types` | adjust |
| DLP profiles | `GET /api/v1/protection/purview/dlp-profiles` | exists |
| Health | `GET /health/checks`, `GET /api/v1/system/*` | exists |

The one‑time Purview prerequisite (`New-ServicePrincipal`) is surfaced in the UI
using `ProtectionCapabilityDto.PurviewAutomation{ApplicationId,ServicePrincipalObjectId}`,
which the API already returns — no backend change needed to render the command.

---

## 10. Why this fixes the complaints

- *"Fails with zero explanation"* → failures translate to a plain sentence + the
  exact one‑time command; the raw code is demoted to "Details".
- *"Download a script and paste strings back"* → replaced by two **Copy** buttons
  and a **Re‑check**; no file, no round‑trip.
- *"Cluttered, mixes Prompt Shields and registration"* → one job per page; the
  separation rule (§3) keeps Prompt Shields, DLP and defaults apart.
- *"Not reactive / modern / slow"* → SPA with client routing, caching and optimistic
  updates; no Blazor Server round‑trips.

See the running app and how to build it in [`web/console/README.md`](../../web/console/README.md).
