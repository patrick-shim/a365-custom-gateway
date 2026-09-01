# A365 Custom Gateway agent instructions

## Durable delivery ledger

Bootstrap work uses the local-only `a365-bootstrap-delivery` skill and its ledger at
`.agent-runtime/bootstrap-delivery/`. Before a bootstrap task action, read
`.agents/skills/a365-bootstrap-delivery/SKILL.md` completely. If
`.agent-runtime/bootstrap-delivery/CURRENT.json` exists, resume it. If it is absent
after a fresh clone or pull onto another computer, seed a new local session from the
tracked [agent continuation checkpoint](docs/agent-continuation.md); do not recreate
current state from chat transcripts, old journal shards, or troubleshooting history.
Record an `Intent` before and a matching `Result` after every material command,
tool call, edit, test, decision, delegation, or external action.

The tracked continuation checkpoint is the cross-computer source-work handoff. The
runtime ledger is the bounded coordination record for one computer and is never
committed. Git also does not transfer `.agent-runtime/`, the legacy
`.agents/runtime/` location, `.bootstrap/`, `bootstrap/config.json`, `.secret`, or
`.secrets`. The legacy location remains ignored only to preserve older local state;
it is not the default or current discovery path. A receiving checkout may continue
source, documentation, and offline validation from the tracked checkpoint, but it
may not claim or resume an existing deployment without that deployment's separately
preserved ignored state and renewed live-action authority.

The coordinator records document/source fingerprints after completing the required
reading below. A delegate with a recorded assignment reads the short current
checkpoint, active journal tail, named handoff, and workstream guide; it does not
reread old journal shards or unrelated status history unless the assignment cites
them. Before any live Azure, SQL, Entra, Graph, Service Bus, Purview, deployment, or
incident action, the acting agent must still read the current deployment checkpoint
and relevant runbook itself.

Every delegated assignment records one owner, exact file or read-only boundaries,
starting checkpoint fingerprint, validation, and stopping condition. `CURRENT.json`
represents coordinator state; a delegate records progress in journal events and its
assigned handoff rather than replacing the coordinator's current objective. The
delegate writes a structured handoff before reporting completion; the coordinator
records a receipt before using it. Never let two agents edit overlapping files
concurrently.

Journals are coordination evidence, not product truth. They rotate at 100 events,
128 KiB, or four hours. Never write credentials, tokens, Gateway keys, prompts,
responses, authorization headers, or raw provider bodies to the ledger.

## Required reading

The session coordinator reads these in order before changing the repository:

1. `docs/implementation-status.md`
2. `docs/agent-continuation.md`
3. `CLAUDE.md`
4. the relevant guide:
   - Admin portal: `docs/agent-guides/admin-ui.md`
   - Agent Identity / Agent 365 provisioning: `docs/agent-guides/provisioning.md`
5. before Azure, SQL, Entra, Service Bus, Graph, deployment, or incident action:
   `docs/operations/development-deployment-status.md` and the applicable runbook

For a fresh subscription, also read `bootstrap/README.md`.

## Authority

When sources disagree, use this order and record the discrepancy:

1. implemented code/tests, deployed Gateway contract, and authorized live evidence;
2. current official Microsoft documentation;
3. current implementation, agent-continuation, and deployment checkpoints;
4. architecture, API, decision, and runbook documents;
5. `docs/spec/product-brief.md` for product intent;
6. agent and skill playbooks.

Never implement a Microsoft endpoint, permission, role, version, or behavior from an
old comment, prototype, or tool without current official validation.

## Current contract

- The Gateway is N:N. Each registration binds one generated external ID, one
  reusable blueprint, one distinct child Entra Agent ID, and one Gateway key
  lifecycle. Ordinary external clients do not submit managed-identity IDs or Entra
  tokens.
- The Admin UI uses the typed blueprint catalog. The API rechecks compatibility and
  every security-sensitive choice before persistence or key issuance.
- The current worker uses seven stable persisted stages and the dedicated
  `gateway-provisioning-v3` queue. Never attach it to an older queue.
- The worker resolves the blueprint/principal, configures Gateway federation,
  creates the child, and assigns Agent 365 access. It then waits at 71%. It never
  calls Agent 365 Registry.
- A signed-in `Gateway.Administrator` completes Registry through
  `POST /api/v1/operations/{id}:complete-agent365-registration`. The endpoint is
  user-only and requires a valid `oid`, delegated `access_as_user`, and OBO.
- The API app's OBO client uses a managed-identity signed assertion. Its FIC has the
  tenant v2 issuer, API Container App managed-identity subject, and sole
  `api://AzureADTokenExchange` audience. Never add a client-secret fallback.
- Registry completion persists a creator-bound planned ID before at most one POST.
  HTTP 201 is persisted immediately. Unknown POST outcomes use exact GET only; the
  POST is never repeated.
- Accepted Registry creation queues only final worker verification. `Active` is set
  only after blueprint, principal, federation, child, OtelWrite, and token mapping
  are reverified.
- The worker Graph role allowlist is exactly eight roles listed in the provisioning
  guide. Registry permissions are delegated API-app scopes, not worker roles.
- Gateway data-plane idempotency is registration/endpoint scoped under a SQL
  application lock. Same hash replays safely; different hash conflicts before side
  effects. One-time secret responses are never replayed.

## Optional protections

Bootstrap deploys and verifies the core Gateway. Prompt Shields and Purview are
optional runtime features and are not required for ordinary registration.

- Prompt Shields calls Azure AI Content Safety with the API managed identity before
  the external model call. An allow returns a short-lived, single-use receipt bound
  to registration, interaction, tenant user, content type, and salted prompt hash.
- Purview Graph v1.0 honors inline and offline execution per activity and fails
  closed. `downloadText` may be offline; do not claim response-side blocking.
- Know Your Data uses Microsoft's fixed tenant-wide enterprise-AI-apps location
  `ee1680d0-702f-4090-b26c-c49091e86531` as `Group`.
- DLP uses the selected reusable blueprint application ID as `Individual`.
- Both use the `Application` enforcement plane. Never merge blueprint IDs into the
  Know Your Data Group.
- Policy readback is not propagation or runtime-verdict proof. Directory role
  assignment is not proof that a cached managed-identity token contains the roles.
- A registration that selects a profile fails closed unless the profile's exact
  independent readback is Ready; optional profile readiness must not close the core
  registration path.

## Bootstrap

- `bootstrap/bootstrap.ps1` is the supported resumable engine. Public users run the
  root `gateway` or `gateway.cmd` launcher.
- State and evidence under ignored `.bootstrap/` contain safe identifiers only.
  Configuration is non-secret.
- Database initialization is allowed only with zero user tables.
- Bootstrap has no destroy mode and does not authorize retained-message access,
  replay, identity cleanup, or SQL finalization.
- If a completed resource group was deleted, preserved state must not recreate it
  in place. Use a new isolated deployment identity or a reviewed recovery plan.
- Bootstrap completion ends with exact deployment readback. Creating an Active
  registration is a post-deployment use task.

## Security and truthfulness

- `.secret` and `.secrets` are private runtime input only. Never read, render,
  print, log, document, copy, alter, transmit, or commit their values.
- Never display or persist clear Gateway keys, credentials, access tokens,
  assertions, authorization headers, prompts, responses, or provider bodies.
- A Gateway key is returned once, stored only as a salted verifier/lifecycle record,
  bound to one registration, and compared in constant time.
- UI role checks improve usability; API authorization is authoritative.
- Preserve RFC 9457 Problem Details, correlation IDs, and claims challenges without
  exposing dependency details.
- Fail closed. Never translate unknown, unsupported, unauthorized, or unverified
  external behavior into `Completed`, `Active`, or “in sync.”
- SQL locking does not make Service Bus exactly once. Every external mutation must
  be independently discoverable and safe after redelivery.
- Equality between IDs never makes different Microsoft resource types
  interchangeable.

## Repository map

- Admin pages: `src/Gateway.AdminUi/Components/Pages`
- Admin auth/API/config: `src/Gateway.AdminUi/Authentication`, `Services`, `Models`,
  `Options`
- Registry API/OBO: `src/Gateway.Api`, `src/Gateway.Application`
- Agent Identity/Agent 365: `src/Gateway.Agent365`
- Purview: `src/Gateway.Purview`
- Durable worker: `src/Gateway.Provisioning.Worker`
- Bootstrap: `bootstrap`
- Azure/SQL assets: `infrastructure`
- Existing-environment operations: `operations`
- Solution: `src/A365Gateway.slnx` (`net10.0`)
- Tests: `tests`

Preserve existing user changes. Agents working in parallel must own non-overlapping
files and must never revert each other.

## Verification

Run the smallest affected gate first, then broader gates:

1. focused unit/Pester tests;
2. full affected project tests;
3. full solution tests and Release build;
4. bootstrap source/Pester/Bicep gates when relevant;
5. format, whitespace, link, and secret-path checks.

UI changes require desktop and narrow-width inspection. Automated tests must never
mutate a live tenant. Local success is source evidence, not deployment evidence.

After an authorized live change, keep exact environment identifiers and digests in
ignored or access-controlled operator evidence. Update the tracked checkpoints with
the non-sensitive result, test/readback status, recovery state, and next action.
Never record secret or tenant-specific material in public documentation.

Before a handoff commit or push, update `docs/agent-continuation.md` with the current
objective, completed evidence, exact first unfinished action, invalidated gates, and
live-action boundary. Keep it bounded and current; detailed chronology stays in Git
history and the rotating local ledger.
