# Protection configuration architecture

This guide describes the retained bootstrap, registration, Settings and runtime
protection contracts. Its historical filename is retained for existing links.
Project acceptance belongs only in [MILESTONES.md](../../MILESTONES.md); current
context belongs in [project state](../project-state.md). No deployment, provider
readiness, test pass count or milestone completion is established here.

## Ownership

| Area | Capability preparation | Application configuration |
|---|---|---|
| Agent 365 Registry beta | Deployment-wide environment and identity admission | Display capability; signed-in Administrator completes each registration |
| Prompt Shields | Shared Content Safety resource, managed-identity role, endpoint and readback | Deployment defaults, independent per-agent use and effective status |
| Purview | Runtime/automation identities, permissions, certificate, Windows execution path and capability readback | Tenant connection, inventory, KYD, shared blueprint policy, reviewed configuration and runtime tests |

Guided fresh setup includes shared Azure AI Content Safety for all presets.
**Full evaluation** includes Purview prerequisites; **Core Gateway** omits Purview
prerequisites; **Custom** chooses Purview independently. Agent-level Prompt Shields
use remains optional. The source retains disabled legacy Content Safety
configuration for source-bound recovery. An unavailable quota does not silently
change SKU or remove the service from a fresh guided plan.

Bootstrap prepares capabilities and verifies their exact resource/identity
bindings. It does not select sensitive information types or author tenant policies.
The retained guided Setup project is absent; its references and reproducible
execution are addressed in M1.

## Shared scope and independent usage

Know Your Data uses the fixed tenant-wide enterprise-AI-apps location
`ee1680d0-702f-4090-b26c-c49091e86531`, with Entra Group scope. A DLP profile uses
one reusable blueprint application ID with Entra Individual scope. Both use the
Application enforcement plane.

One blueprint profile is shared by registrations using that blueprint. Individual
does not mean per-agent isolation. A policy change can affect other agents and
requires acknowledgement of that impact. Switching one agent's Purview use off
does not turn off or delete the shared policy.

Prompt Shields and Purview choices are independent. Requested choices, configured
policy, capability availability, simulation and effective enforcement must be
reported separately. Ordinary registration can proceed without optional per-agent
protection.

## Tenant connection and inventory

An Administrator starts a reviewed, confirmed connection operation for the exact
tenant. The bounded Windows companion performs interactive compliance sign-in and
returns typed identity, authorization and inventory facts. The Gateway rechecks
actor, operation and authority before accepting them. Provider tokens and
certificate material are not returned through that handoff.

Sensitive information types (SITs) come from the current tenant inventory. A
selection binds GUID, exact Unicode name and inventory generation; it does not
come from a static catalog or free-text name. Expired inventory, missing/renamed
types or changed authority requires renewed review.

The DLP profile supports multiple selected SITs with OR semantics: any selected
type can match. Each type keeps its own count and confidence thresholds; counts
are not summed across types. Minimum count is positive; maximum count is -1
(unbounded) or at least the minimum. Confidence bounds are inclusive from 1 to
100, with maximum at least minimum. Existing shared policy edits require explicit
threshold evidence; unknown values are not silently replaced with defaults.

## Policy modes

The API/domain modes map to provider modes as follows:

| API/domain mode | UI wording | Provider mode | Meaning |
|---|---|---|---|
| Enforce | Enforce | Enable | Requires current runtime certification before effective enforcement |
| SimulationWithTips | Simulation with policy tips where supported | TestWithNotifications | Nonblocking simulation; tips depend on provider support |
| SimulationWithoutTips | Silent simulation | TestWithoutNotifications | Nonblocking simulation without tips |
| Disabled | Configured off | Disable | Policy remains configured and disabled |

Legacy Enforce maps to Enforce; legacy AuditOnly maps to
SimulationWithoutTips. SimulationReady and Disabled preserve verified
configuration facts without claiming an allow/block enforcement result.

The retained rule contract uses supported activity/action pairs. Offline
DownloadText processing cannot establish response-side blocking. Changing a
shared mode, classifier or threshold invalidates protection proof tied to the
prior configuration.

## Registration and later editing

The same reviewed configuration service supports registration, agent editing and
Settings. A registration can reuse an already verified profile or submit a
reviewed and confirmed configuration intent.

For an existing blueprint, the operation binds to its exact application ID and
checks shared impact and optimistic concurrency. For **Create new blueprint**, the
review binds to the generated external ID and requested blueprint name. Its
accepted operation enters AwaitingBlueprint, with the original actor, intent hash
and consumed confirmation retained.

After core provisioning reaches Active, an internal worker continuation verifies
the new registration/blueprint binding and current connection/inventory. It
creates the bound profile and queues protection work atomically with the
continuation. An existing-profile conflict or expired authority yields a manual
review action; it does not silently adopt another policy or invent new consent.

This separation preserves the seven-stage core registration workflow. A
configuration request is not proof that the agent is already protected.

## Review, confirmation and authorization

The API enforces delegated Administrator authority for protection mutation and
rechecks tenant, user object ID, target, operation and payload. Operator, Auditor
and SupportReader access is restricted to their allowed status views.

Reviews bind the exact tenant, blueprint/scope, inventory, selected SITs and
thresholds, mode, activities/actions and shared-policy impact. A short-lived review
value is exchanged for a single-use confirmation. Mutation also checks canonical
UUIDv4 idempotency and row-version concurrency. A review response alone does not
authorize execution.

Changed scope, inventory, payload, actor, row version or expiry invalidates the
confirmation. Errors use bounded codes and correlation IDs. Browser refresh
recovers durable operation state, not a reusable interactive sign-in or secret.

See the [API contract](../api/api-contract.md) for request fields and routes.

## Durable policy administration

Ordinary provider operations use a transactional outbox and the dedicated
`gateway-protection-admin-v1` queue. Their eight persisted stages are:

1. Validate Reviewed Intent.
2. Discover Provider State.
3. Apply Reviewed Mutation.
4. Record Exact Readback.
5. Verify Propagation.
6. Attest Token Roles.
7. Validate Runtime Verdict.
8. Complete.

These stages are distinct from registration workflow v3 and
`gateway-provisioning-v3`. Each operation retains reviewed intent and exact
provider identifiers. Unknown writes require exact readback rather than blind
repetition. The worker uses the private
[Windows executor](purview-windows-executor.md) for certificate-backed compliance
operations.

Capability installation, directory-role assignment, policy readback, propagation,
runtime-token roles and observed behavior remain separate facts. A platform
Running state is not policy or data-plane proof.

## Approved runtime sample tests

The current runtime-test API provides:

- `POST /api/v1/protection/purview/dlp-profiles/{id}:review-runtime-test`
- `POST /api/v1/protection/purview/dlp-profiles/{id}:test-runtime`
- `GET /api/v1/protection/runtime-tests/{operationId}`

Review binds a synthetic sample manifest and exact deployment, profile,
registration, inventory and mode context. After confirmation, execution verifies
sample hashes and limits, commits acceptance, then runs provider work
synchronously. Raw samples remain ephemeral; they are not sent through the
protection queue or stored in operation records.

A batch supports up to eight positive samples plus its negative sample, 8 KiB per
sample and 64 KiB total. The execution deadline is 60 seconds. Durable status
retains sanitized observations and distinguishes behavior observed, submission
accepted, not verified, failure and unknown outcomes.

Enforce proof requires the negative sample to be allowed and positive samples to
be blocked through content processing. A protection-scope response alone does not
prove sample behavior. Simulation can report nonblocking observations or accepted
submission without claiming enforcement. Disabled mode cannot run a test.

An administrator's association between a sample and a SIT is not provider-reported
classifier attribution; the runtime result reports SIT match attribution as
unavailable. Certification is limited by current context and evidence expiry,
including a maximum evidence age of 30 minutes. Changed context invalidates old
proof. Recovery does not repeat an uncertain sample submission.

## Prompt gate and readiness

Prompt Shields requires exact installed Content Safety readback. Purview Enforce
requires the exact shared profile, current capability/tenant/inventory, propagation,
token-role evidence and valid runtime certification. Missing requested
enforcement remains fail-closed rather than silently turning off protection.

Prompt receipts bind the registration protection revision and current context,
including shared policy mode and thresholds. They are single-use and expire no
later than their governing proof. Changes to effective protection invalidate prior
receipts.

## Compatibility and further work

The source retains legacy combined profiles, review-required migration candidates
and legacy request fields. They do not establish readiness. Bounded
[upgrade operations](../../operations/gateway-upgrade.md) exist alongside the
older review-only maintenance surface; original bootstrap state and separately
bound upgrade receipts serve different operational purposes.

The former tests and three referenced tool projects are absent. Reproducible
builds, regression tests, Chrome journeys and fresh hosted acceptance are tracked
in M1 through M6, with whole-project documentation synchronization at each closure.
No historical pass total or runtime receipt substitutes for those checklist items.
