# A365 Gateway — UI design system & platform direction

Authoritative UI platform for **every** Gateway user interface: hosted Console,
guided Setup/bootstrap, and any future operator surface. Product objective,
scope, and behaviors stay in the [product brief](../spec/product-brief.md).

> TL;DR — **All UIs** move to one **React + TypeScript + Fluent UI v9** stack:
> reactive, sleek, flexible, fast, and responsive. **C# / .NET stays** for API,
> worker, Purview executor, and migrator. PowerShell stays for bootstrap
> orchestration. Blazor Admin UI and the legacy Setup app are transitional only.

---

## 1. Decision and scope

| Area | Decision | Why |
|---|---|---|
| **All frontends** | One React + TypeScript SPA family (Console + Setup). No new Blazor/Razor. | Blazor Server round-trips feel laggy; one stack keeps UX and hiring coherent. |
| **Hosted Console** | Replace `Gateway.AdminUi` after feature cutover into bootstrap. | Same `/api/v1` contract; Fluent SPA is the long-term operator UI. |
| **Guided Setup UI** | Replace `Gateway.Setup` UI with the same React + Fluent stack; keep PowerShell plan/apply/verify engine. | Install is part of the product experience; it must match Console quality. |
| **Backend** | Keep C# / .NET API, worker, Windows Purview executor, DatabaseMigrator. | Control plane is solid; Purview executor must stay Windows + PowerShell. |
| **Contract** | Hosted Console uses MSAL-acquired delegated bearer on `/api/v1/*`. | API authorization remains authoritative. |

**New UI is React + Fluent only.** Do not expand Blazor or the legacy Setup UI
except for critical deploy-path fixes. Decommission legacy UIs when the matching
React surface reaches acceptance (§8).

---

## 2. Surfaces

| Surface | Users | Today | Target |
|---|---|---|---|
| **Console** (`web/console`) | Administrator, Operator, Auditor, Support | Partial React SPA; not in bootstrap; Policies incomplete | Bootstrap-deployed Fluent Console; full Admin UI parity then Blazor retired |
| **Setup** (today `tools/Gateway.Setup`) | Deployer during install | Legacy guided Setup app | React + Fluent Setup shell driving the same bootstrap engine |
| **External developer** | Integrators | API + sample client | Unchanged (no operator UI) |

---

## 3. Personas — Console information architecture

| Persona | Does | Rhythm | Zone |
|---|---|---|---|
| **Deployer** | Bootstraps the Gateway, picks region/SKUs/capabilities, clears one-time admin actions, checks health, upgrades | Once, then rare | **Platform** (and **Setup** during install) |
| **Operator** | Registers agents, issues the one-time key, enable/disable, rotate key, flips Prompt Shields per agent | Daily | **Agents** |
| **Policy manager** | Connects Purview, reviews classifiers (SITs), sets DLP per blueprint, tests behaviour | Setup, then occasional | **Data protection** |

```
Home  ── "Needs attention" across all zones

Agents            (Operator)
  ├─ Agents list
  ├─ Register agent        (Name → Blueprint → Key)
  └─ Agent detail          (Prompt Shields · Identity · API key · Activity)

Data protection   (Policy manager)
  ├─ Connection
  ├─ Classifiers (SIT)
  └─ Policies (DLP)        (editor, modes, behaviour tests)

Platform          (Deployer)
  ├─ Health
  ├─ Defaults              (incl. Prompt Shields default)
  └─ Access (roles)
```

### Separation rule

| Control | Owner | Lives on | Shape |
|---|---|---|---|
| **Prompt Shields** | Operator | the **Agent** | one On/Off toggle |
| **DLP / SITs** | Policy manager | **Data protection** | policy editor |
| **Defaults** | Deployer | **Platform** | set once |

On the **target Console**, Prompt Shields and DLP never share a screen, and
registration does not block on protection knobs (name → blueprint → key). The
**API and legacy Admin UI** may still offer optional feature/protection choices
during registration; that remains valid until Console cutover. After registration,
all optional controls remain available on their proper surfaces.

---

## 4. Design directives

These are rules for every Gateway UI, including Setup.

**Plain and short**
- One job per page. If a page answers two questions, split it.
- Max one line of helper text under any control.
- Lead with the action. Plain words: *Needs setup, On/Off, Running, Register once*.
- Raw codes (`PURVIEW_CONNECTION_PROVIDER_UNVERIFIED`) belong under Details.

**Reactive / instant**
- No full-page blocking spinners where a section spinner or skeleton will do.
- Never present a protection change as effective until server readback confirms it.
- Client-side routing; TanStack Query cache/revalidation.
- Async status announced politely (`aria-live`) and shown inline.

**Sleek / modern / Fluent**
- Fluent UI v9 design tokens; generous whitespace; one accent; restrained colour.
- Consistent components (status pills, copyable values, page headers).
- Motion is subtle and respects `prefers-reduced-motion`.

**Flexible / responsive**
- Responsive down to tablet; shell collapses the nav.
- Light / dark / high-contrast via Fluent themes — no hard-coded colours.
- Role-aware: zones and actions render per role; read-only is first-class.

**Intuitive**
- Progressive disclosure; single "Needs attention" home for cross-zone work.
- Dangerous or one-way actions confirm in plain words.

---

## 5. Technology stack (mandatory for all new UI)

| Concern | Choice | Notes |
|---|---|---|
| Language | **TypeScript** (strict) | `noUnusedLocals`, `noUnusedParameters`, strict null checks |
| UI library | **React** (current major) | function components + hooks only |
| Build/dev | **Vite** | fast HMR, static output |
| Design system | **Fluent UI React v9** (`@fluentui/react-components`) | Microsoft-native look, tokens, themes, a11y |
| Server state | **TanStack Query** | caching, revalidation, optimistic updates where safe |
| Routing | **React Router** | client-side routes with recoverable error boundaries |
| Auth (hosted Console) | **MSAL React** | Entra OIDC + delegated API bearer |
| Unit/component tests | **Vitest + Testing Library** | jsdom |
| E2E | **Playwright** | live acceptance journeys |
| Lint/format | **ESLint + Prettier** | required for new UI packages |
| Packaging | static assets (nginx or API-hosted) | replaces Blazor UI image; Setup may run locally via Vite during install |

Do not mix a second component system (for example Tailwind + Radix) into the same
Fluent surface. Backend remains C#; do not rewrite API/worker/executor in Node.

---

## 6. Component and content standards

- **StatusPill** — status → plain words + tone. One source of truth.
- **CopyableCommand / CopyableValue** — read-only value + Copy; visible clipboard errors. One-time keys never enter query caches or persistent browser storage.
- **PageHeader** — title + one-line subtitle + optional primary action/status.
- **AppShell** — persona-zoned left nav, signed-in identity, content column.
- **Failure codes** — human sentence first; raw code under Details.

Current Console implementation: [`web/console/src`](../../web/console/src).
Setup UI target package: to be introduced under `web/` (or equivalent) and wired
through `gateway` / `gateway.cmd`; the PowerShell engine remains authoritative for
Azure mutation.

---

## 7. Accessibility and internationalisation

- Target **WCAG 2.1 AA**. Full keyboard operability; visible focus; logical tab order.
- Async regions use `role="status"` / `aria-live="polite"`.
- Respect `prefers-reduced-motion` and `prefers-color-scheme`.
- Centralised, translatable copy; no concatenated sentences that break i18n.

---

## 8. Implementation and acceptance boundaries

| Surface | Current implementation | Acceptance for retirement of legacy |
|---|---|---|
| Console navigation | React routes; loading/error/empty; shell survives render failures | Authenticated menu-click journeys stable |
| Agents | Registration, keys, Prompt Shields, Registry confirmation, operation progress | Parity with legacy Admin UI registration/lifecycle |
| Connection | Gateway `verificationMode` review/confirm/start | Connected only after independent provider readback |
| Classifiers | Inventory + expiration | Refresh requires verified connection |
| Policies | **Read-only** list today | Editor + behaviour tests before Blazor Settings retirement |
| Platform | Health/capabilities/defaults | No fabricated worker health |
| Packaging / bootstrap | Console image exists; **not** in bootstrap yet | Console in bootstrap deploy/open/upgrade path |
| Setup UI | Legacy `Gateway.Setup` | React + Fluent Setup drives doctor/init/plan/apply/verify without losing engine contracts |

Persona zones do not alter authorization. Backend roles remain authoritative.

The Console requests `verificationMode: "Gateway"` at connection review and start.
It must verify the returned mode and `VerifyPurviewTenantConnection` before
confirmation. API and worker must be upgraded together before new Console
operation types are enabled. See
[cutover notes](../../web/console/README.md#api-and-worker-cutover).

Registration defaults are server-owned. Production is the standard contract
default; DirectRegistryPreview may advertise Development with a reason.
Registry completion HTTP 200 queues verification — not Active.

Acceptance requires the exact deployed image (or Setup package) to pass
authenticated journeys. Connection verification, policy readiness, runtime
enforcement, downstream delivery, and human approval are separate outcomes;
none may be inferred from HTTP 200/202 or a successful build.

---

## 9. Authoritative backend contracts

Use existing `Gateway.Contracts` DTOs and controller routes. Unknown response
shapes are errors, not empty success.

| Need | Endpoint | Status |
|---|---|---|
| Agents list / detail | `GET /api/v1/agents`, `GET /api/v1/agents/{id}` | exists |
| Per-agent Prompt Shields | `PATCH /api/v1/agents/{id}/features` | `If-Match` and idempotency required |
| Register agent | `POST /api/v1/agents` (+ key issue) | exists |
| Registration defaults | `GET /api/v1/system/config` | server-owned defaults; no environment selector |
| Registry progress | `GET /api/v1/operations/{id}` | from `provisioning.operationId` |
| Registry completion | `POST /api/v1/operations/{id}:complete-agent365-registration` | bodyless; exact-ID recovery |
| Blueprints | `GET /api/v1/agent-identity-blueprints` | `{ items: [...] }` |
| Purview connection | `GET /api/v1/protection/purview/connection` | `{ connection: object or null }` |
| Connection check | review → confirm → start under `/api/v1/protection/` | `verificationMode: "Gateway"` |
| Operation readback | `GET /api/v1/protection/operations/{id}` | `{ operation: ... }` |
| Classifiers (SIT) | `GET /api/v1/protection/purview/sensitive-information-types` | inventory + `exactName` |
| DLP profiles | `GET /api/v1/protection/purview/dlp-profiles` | readiness is an object |
| Platform | `GET /health/checks`, protection capabilities, system config | distinct concerns |

`:enable` / `:disable` change agent lifecycle, never Prompt Shields.

---

## 10. Why this direction

- One modern stack for Console **and** Setup — no permanent Blazor/Setup split.
- C# backend preserved where it already owns security, durability, and Purview.
- Fluent + TanStack Query delivers reactive, fast, responsive operator UX.
- Clear current-vs-target tables prevent mistaking migration work for shipped parity.

See the Console package: [`web/console/README.md`](../../web/console/README.md).
Product contracts: [`product brief`](../spec/product-brief.md).
