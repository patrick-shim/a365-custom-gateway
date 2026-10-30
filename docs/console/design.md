# Console design

The React/Fluent UI Console uses a navy navigation rail, compact headers, layered cards, consistent tables and agent-detail tabs. Fluent theme overrides live in `web/console/src/theme.ts`; shell and surface styles live in `base.css`.

The container serves the SPA and same-origin API routes through Nginx. That proxy
re-resolves the Compose `api` service through Docker DNS while Nginx is running,
so API container recreation does not strand the Console on a retired container
address or require a Console restart. Existing paths, query strings,
authorization forwarding, API-reference routes, and health routes are preserved.

## Navigation and workflows

- Agents: server-side search and pagination, registration, authoritative setup progress, detail tabs and lifecycle actions.
- Data protection / Policies: fresh existing-policy catalog, compatibility, individual-agent assignment and observed enforcement status.
- Settings / Gateway: gateway defaults with reviewed protection changes.
- Settings / Purview: ongoing connection diagnostics; initial setup belongs to bootstrap.
- API reference: opens the live interactive reference at `/docs` in a separate tab.

Each agent separates Prompt Shields, Data protection, Identity, API key and Activity. The Console does not author classifiers, sensitive information types or policy rules. Registration confirmation requires delegated administrator access and is distinct from policy assignment.

## Truthful interaction states

Show server-confirmed state. Registration progress polls the authoritative operation and stops animating when administrator confirmation is required. Protection changes display a saving state; concurrent changes require refresh and a renewed review.

An initial read uses a clear loading state. A background refresh keeps the last
confirmed content visible and adds a compact animated “Refreshing” indicator.
Buttons name the active action, prevent duplicate submission, and return to their
normal label at a terminal outcome. Success, warning, blocked, and failure states
use consistent Fluent colors and icons while retaining explicit text for color-
independent meaning.

Errors distinguish expired sign-in, missing permission, stale/conflicting state,
temporary gateway availability, and unconfirmed mutation outcome. The primary
message says what happened; a short recovery line says what the operator can do.
Technical codes and correlation references remain collapsed under Details. Raw
provider responses, prompts, tokens, and credentials never appear.

Registration validates the external agent ID's 3–128 character domain constraint
before leaving the first step and shows the constraint beside the field. Registry
confirmation finishes within the Console request window. When Microsoft throttles
or delays exact-ID readback, the Console identifies the outcome as unconfirmed,
stops active animation, and directs the administrator to refresh and reconcile
the existing operation after waiting; it never claims that creation completed.

Policy assignment distinguishes applying, assigned/awaiting verification, current allow/block observations, failure and unavailable status. Applying assignment displays elapsed time and last successful status readback. Stop indicating active progress when status cannot be read. A write or elapsed time alone does not establish synchronized enforcement. Cached data must not conceal a failed catalog refresh.

API keys are visible once and are not retained in query caches. Role-aware controls supplement server authorization. Search cursors and operation identifiers come from the server. Failed or uncertain mutations must not display fabricated success.

## Purview connection and Manual sync

The Settings / Purview page reads the local connection record and exposes
the six server states: `NotConfigured`, `Connecting`, `Connected`, `Refreshing`,
`Degraded`, and `Disconnected`. It maps them to **Connect to Purview**, in-progress
feedback, **Manual sync**, **Retry manual sync**, or **Reconnect**. Connect
requires an explicit confirmation and uses only the identity, certificate,
permissions, and listener installed by bootstrap.

The page shows manual mode, tenant, local connector profile and instance,
heartbeat, last attempt, last success, catalog retrieval age and verification,
compatible/incompatible counts, failure code, and correlation reference. **Check
status**, its 60-second local status refresh, page load, focus, and browser reload
only read PostgreSQL state; they never submit provider work.

Six missed five-second authenticated heartbeats make listener readiness stale.
The server reports `Degraded` while retaining an accepted catalog, or
`Disconnected` when none exists. Heartbeat recovery restores only this
liveness-induced state and does not retrieve policy content.

Connect and Manual sync return an accepted durable operation. The Console does
not call that completion. It polls the same operation about every three seconds,
replaces the existing progress state, and stops for `Succeeded`, `Failed`,
`NeedsAttention`, `TimedOut`, or `Cancelled`, or when operation status cannot be
read. An unchanged live response remains valid progress evidence because a provider
read can take several minutes; the Console continues polling while the API returns
`Pending` or `Running` with polling recommended. The server operation deadline
bounds the wait. A read error stops active animation and offers **Check operation
status**. Duplicate mutation controls remain disabled while a submission or live
operation is active.

The action remains disabled while the API performs any bounded local contention
retry. If the API cannot accept the operation, the Console shows its sanitized
problem and correlation reference, then rereads authoritative connection state
without claiming that a refresh started.

A failed refresh preserves the previous verified catalog and labels the connection
Degraded; the UI explains that management failure alone does not prove configured
agents lost runtime protection. Policy and agent pages reload the saved accepted
catalog and link to Manual sync rather than implying that local reload contacts
Purview. Catalog age alone does not label a durable assignment unavailable.

The **Manual sync** button retrieves the policy list on demand. The prior accepted
catalog has no age expiry and remains usable for selection and review while sync
is running or the management connector is unavailable. A failed sync retains the
list and its last sync time. A successful sync replaces it. When an open agent
page observes a newer accepted revision, it loads that version before the next
review. Applying an assignment still verifies the selected policy live.

Thirty seconds without an authenticated listener heartbeat is a local management-
readiness failure. The page shows `Degraded` and retains the dated accepted catalog
when one exists, or `Disconnected` when none exists, with
`PURVIEW_CONNECTOR_UNAVAILABLE` repair guidance. A later authenticated heartbeat
restores only this liveness-induced state and does not start a policy refresh.

Assignment status includes `NeedsAttention`. The page derives it from the signed
internal `definitionRevision` and this agent's exact all-accounts target evidence,
not from a change to public whole-scope `revision` alone. Adding a separately
reviewed agent to the same policy leaves existing agents assigned without warning
when their exact targets and enforcement semantics remain unchanged. A refresh-
proven removal, narrowing/exclusion, material rule/mode/definition change,
incompatibility, or no-longer-targeted identity is shown as requiring review and
cannot be presented as a current binding. Assignment completion and runtime
allow/block evidence remain separate.

## Theme, motion and accessibility

The header's Dark theme switch controls Fluent and custom surfaces. The latest choice is saved locally, restored on reload and synchronized across open Console tabs. New browsers start in dark mode; unavailable storage limits persistence to the current session.

Short navigation and hover transitions respect reduced motion. Real pending actions use progress indicators. Decorative animation never implies service health, policy propagation or enforcement. A skip link, visible keyboard focus, narrow-screen navigation and forced-color fallbacks support accessibility.

## Installer

React Setup is a separate frontend served by the local setup host. It collects the same settings as the terminal interface and invokes the same reviewed PowerShell plan/apply/verify flow. Its nonce/session isolation and request validation protect the local control surface. It does not duplicate provisioning logic in the browser.

Run [Console and setup tests](../../tests/README.md) before deploying UI changes. Backend API contracts and permission checks remain authoritative.
