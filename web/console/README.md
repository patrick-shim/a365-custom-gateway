# A365 Gateway Console

Modern **React + TypeScript** single‑page app for the A365 Custom Gateway. It
replaces the Blazor Admin UI and talks to the existing .NET REST API (`/api/v1/*`).

Design and direction: [`docs/console/design.md`](../../docs/console/design.md).

## Stack

Vite · React 18 · TypeScript (strict) · Fluent UI React v9 · TanStack Query · React Router.

## Run it

```bash
cd web/console
npm install
npm run dev        # http://localhost:5173
```

By default the app runs on **mock data** (mirrors the `gw40397-dev` deployment), so
it works with no backend. Demo helpers:

- `http://localhost:5173/?connected=1` — show Purview in the connected state.

### Against the real API

```bash
# point the dev proxy at a Gateway API and use the live client
set GATEWAY_API_BASE_URL=https://ca-gateway-api-dev.<region>.azurecontainerapps.io
set VITE_USE_MOCK=0
npm run dev
```

(Live client endpoints are wired in phase 2 — see the design doc §8–§9.)

## Build / check

```bash
npm run build       # tsc -b && vite build  → dist/
npm run typecheck
```

## Layout

```
src/
  api/        types.ts · client.ts (live + mock switch) · mock.ts
  components/ AppShell · PageHeader · StatusPill · CopyableCommand
  pages/
    Home.tsx                      "Needs attention" landing
    agents/                       AgentsList · AgentDetail · RegisterAgent
    dataprotection/               Connection · Classifiers · Policies
    Platform.tsx
```

## Three persona zones (see design doc)

- **Agents** — register, keys, per‑agent Prompt Shields, activity.
- **Data protection** — Purview connection, classifiers, DLP policies.
- **Platform** — health, defaults, access.

Prompt Shields lives on the agent; DLP lives in Data protection; defaults live in
Platform. They never share a screen.
