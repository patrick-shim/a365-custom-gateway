# Console design

The React/Fluent UI Console uses a navy navigation rail, compact headers, layered cards, consistent tables and agent-detail tabs. Fluent theme overrides live in `web/console/src/theme.ts`; shell and surface styles live in `base.css`.

## Navigation and workflows

- Agents: server-side search and pagination, registration, authoritative setup progress, detail tabs and lifecycle actions.
- Data protection / Policies: fresh existing-policy catalog, compatibility, individual-agent assignment and observed enforcement status.
- Settings / Gateway: gateway defaults with reviewed protection changes.
- Settings / Purview: ongoing connection diagnostics; initial setup belongs to bootstrap.
- API reference: opens the live interactive reference at `/docs` in a separate tab.

Each agent separates Prompt Shields, Data protection, Identity, API key and Activity. The Console does not author classifiers, sensitive information types or policy rules. Registration confirmation requires delegated administrator access and is distinct from policy assignment.

## Truthful interaction states

Show server-confirmed state. Registration progress polls the authoritative operation and stops animating when administrator confirmation is required. Protection changes display a saving state; concurrent changes require refresh and a renewed review.

Policy assignment distinguishes applying, assigned/awaiting verification, current allow/block observations, failure and unavailable status. Applying assignment displays elapsed time and last successful status readback. Stop indicating active progress when status cannot be read. A write or elapsed time alone does not establish synchronized enforcement. Cached data must not conceal a failed catalog refresh.

API keys are visible once and are not retained in query caches. Role-aware controls supplement server authorization. Search cursors and operation identifiers come from the server. Failed or uncertain mutations must not display fabricated success.

## Theme, motion and accessibility

The header's Dark theme switch controls Fluent and custom surfaces. The latest choice is saved locally, restored on reload and synchronized across open Console tabs. New browsers start in dark mode; unavailable storage limits persistence to the current session.

Short navigation and hover transitions respect reduced motion. Real pending actions use progress indicators. Decorative animation never implies service health, policy propagation or enforcement. A skip link, visible keyboard focus, narrow-screen navigation and forced-color fallbacks support accessibility.

## Installer

React Setup is a separate frontend served by the local setup host. It collects the same settings as the terminal interface and invokes the same reviewed PowerShell plan/apply/verify flow. Its nonce/session isolation and request validation protect the local control surface. It does not duplicate provisioning logic in the browser.

Run [Console and setup tests](../../tests/README.md) before deploying UI changes. Backend API contracts and permission checks remain authoritative.
