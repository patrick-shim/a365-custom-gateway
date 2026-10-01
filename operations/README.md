# Operating a Gateway

This directory retains scripts and lifecycle contracts for an existing Gateway.
The user deliberately removed the original Azure resources. A separately owned
M5 qualification installation now exists; its current context is in
[project state](../docs/project-state.md), not in historical repair scripts.
For a new installation, start with the
[bootstrap guide](../bootstrap/README.md).

Fresh canonical installation and read-only verification have been exercised for
release qualification. This does not certify every existing-environment upgrade,
incident repair or recovery path. Setup, DatabaseMigrator and LiveVerification
sources and local test fixtures are restored; retained scripts and old output
directories do not establish acceptance for a different target.

[MILESTONES.md](../MILESTONES.md) is the sole completion and acceptance record.
Follow [AGENTS.md](../AGENTS.md) for authorization, the selected Azure target,
credential handling and browser preferences. Existing explicit authorization
persists within its scope. Historical prose is not a reason to request it again.

## Retained command surface

These commands describe the intended lifecycle once its prerequisites and target
state are verified; they are not instructions to recreate deleted resources now.

| Command | Purpose and effects |
|---|---|
| `./gateway status` | Read local bootstrap checkpoint state. |
| `./gateway verify` | Run the live, read-only deployment verifier. |
| `./gateway diagnose` | Create a sanitized local diagnostic bundle. |
| `./gateway open` | Open the Admin UI recorded in verified state. |
| `./gateway resume` | Reconcile and continue an eligible interrupted bootstrap; may mutate the target. |

Use `gateway.cmd` for the Windows launcher. A preserved `.bootstrap/` checkpoint
is operational reconciliation data, not project acceptance. Do not edit it to
force progress or replay completed state against deliberately deleted resources.

## Retained scripts and guides

| Script or guide | Scope |
|---|---|
| [Provisioning preflight](test-provisioning-prerequisites.ps1) | Read-only Agent ID and provisioning checks against the selected live target. |
| [First registration verifier](verify-first-registration.ps1) | Verify an explicitly selected Active registration; its temporary-key lifecycle includes mutations. |
| [Admin UI promotion](upgrade-bootstrap-admin-ui.ps1) | Promote the Admin UI in an eligible completed deployment through `gateway upgrade-admin-ui`. |
| [First-registration state contract](FirstRegistrationVerificationState.psm1) | Preserve verification and temporary-key reconciliation state. |
| [Versioned upgrade](gateway-upgrade.md) | Candidate, plan, promotion, verification, rollback and bounded abort contracts. |
| [Maintenance v1 contract](gateway-maintenance.md) | Historical baseline/plan scaffold; not an alternate execution path. |

An Admin UI-only successor does not require rolling the portal back to its
original bootstrap image. The canonical promotion discovers exactly one prior
receipt for the live immutable image in its owned receipt directory, validates
the original Plan/source/identity bindings, and freshly reads ACR, ARM, identity
and HTTP state. An earlier `Accepted` receipt with a `Succeeded` deployment can
be independently reverified; its bytes and status remain unchanged.
The new immutable `acceptedPlan.priorUpgrade` records that predecessor's receipt,
Plan/source fingerprints and the current verifier provenance. Missing, ambiguous,
incomplete or conflicting history blocks a successor. Same-source interrupted
work still resumes its own exact receipt rather than creating a new attempt.
This narrow path does not deploy API/worker/SQL or replace full-release validation.
Read-only receipt verification is shared with Full maintenance through
[GatewayAdminUiReadback.psm1](GatewayAdminUiReadback.psm1); future UI promotion
provenance hashes both that module and its driver. The Full verifier preserves
original bootstrap images and independently checks the current promoted UI
before and after its complete readback. See the
[source-only Full contract](gateway-upgrade.md#source-only-maintenance-of-an-installed-full-deployment)
for exact custom-target admission, separate original/current image reports and
protected worker configuration checks. Neither local admission nor an individual
passing readback is permission to deploy a mixed API/worker/executor release.

Some `operations/test-*` scripts call real providers or exercise mutable workflows.
Review their source and target requirements before running them; their names do
not imply offline tests. The old `gw0911g` hotfix and repair scripts are retained
incident-specific source, **not current setup, upgrade or recovery steps**.

The [local baseline runner](../tools/Test-LocalBaseline.ps1) explicitly includes
only the portable packaging, abort-journal and Purview-metadata scripts below,
each in a separate PowerShell process. It does not discover all operator scripts.

| Retained test script | Boundary and prerequisites |
|---|---|
| [Packaging boundary](test-gateway-upgrade-packaging.ps1) | Local source fixture files; no provider or package build. |
| [Abort lifecycle](test-gateway-upgrade-abort.ps1) | Synthetic local journal/authority fixtures; no provider or lease calls. |
| [Purview policy metadata](test-purview-policy-metadata.ps1) | Loads only validator functions from the parsed authored script; no provider calls. |
| [Source-only maintenance](test-gateway-upgrade-source-only.ps1) | Reads preserved bootstrap/configuration inputs; excluded from the clean M1 suite because it requires historical environment artifacts. |
| [Startup diagnostic package](test-gw0911g-startup-diagnostic-package.ps1) | Inspects previously published package bytes; excluded from M1 source-only verification. |

All retained hotfix/repair wrappers, executor-capacity repair and Admin UI promotion
have provider-mutating modes. A locally displayed Plan or an offline test of a
validator does not make their Apply/Execute modes safe to run as unit tests.

## Protection operations

See the [protection design](../docs/architecture/protection-settings-plan.md) and
[Windows executor architecture](../docs/architecture/purview-windows-executor.md)
for the retained contracts. Provisioned capability, saved configuration and
runtime-proven protection are separate states.

Settings provides focused connection/inventory, shared-policy, runtime-test,
collection and defaults routes. Its current-protection summary uses the saved
profile and bounded readiness snapshot, not configuration-operation completion.
Expiry or changed context requires fresh readback; a prior report is historical,
and intentionally Off is not an incomplete core registration.

Each task now explains what happened, why it matters, what remains unverified
and the next permitted action before its collapsible technical details. A
completed connection continues to shared-policy review, not an enforcement
claim. Approved Enforce configuration continues to a separately approved runtime
test; current test results continue to explicit agent choices and telemetry
verification. Exact profile links preserve the intended shared scope.

The four-step guide makes that order explicit while allowing earlier steps to
be revisited. Connection shows the validated SIT count; the policy editor is the
single place to choose policy types and adjust explained thresholds. Saved
policies remain available below it in a disclosure. Activity cues describe actual
UI requests or automatic status reads, not Microsoft completion estimates, and
retain their meaning when reduced motion is enabled.

A policy failure during slow provider reads is not necessarily a bad SIT
selection. Read the retained operation first. If its inventory expired, renew the
connection, then use **Review existing policy check** on that exact saved policy.
A new confirmed/accepted review can bind unchanged settings to genuinely current
inventory and invalidate old proof. Microsoft reconciliation is read-only; absent
IDs, partial results or unknown outcomes never permit an automatic new create.
This recovery does not turn on an agent or certify enforcement.

The UI observes its retained pending operation by read-only GET every three
seconds, for at most five minutes per automatic-update session. Terminal
readback also refreshes current connection/inventory/profile context; a failed
refresh cannot leave stale controls usable. Stop/resume controls affect only UI
observation, never durable work. An error or unknown result retains the same
operation for readback rather than submitting another mutation or sample.
Recovery uses only the current task's required reads, so an unrelated retained
error does not require repeating setup. A runtime result's replacement readiness
deadline updates both the summary and its expiry timer; an old receipt must not
keep an Enforcing badge alive.

Know Your Data uses the fixed tenant-wide enterprise-AI-apps location as
`LocationType=Group`; blueprint-specific DLP uses the reusable blueprint
application/client ID as `LocationType=Individual`. Both use the Application plane.

Collection enablement is separate from DLP simulation.
`New-FeatureConfiguration` and `Set-FeatureConfiguration` support native
`Enable`/`Disable`. The Gateway's legacy `AuditOnly` and `Enforce` collection
choices both map to an enabled collection policy. Do not send DLP
`TestWithoutNotifications` or `TestWithNotifications` as collection-policy modes.

For a collection scoped to a specific sensitive information type,
`IsIngestionEnabled=false` preserves that scope. The flag controls full AI content
capture, not collection enablement. Full content capture requires the All
classifier scope; a saved choice must not be silently widened.

### Purview automation reference prerequisite

The human companion and the Gateway use different sign-ins. The companion proves
the intended administrator can read the classifier catalog. The Gateway then
uses its configured automation application and certificate. An Entra app that
exists and can sign in can still be missing its separate Security & Compliance
service-principal reference. The connection verifier checks that reference;
the installer and companion do not currently create it.

Use this bounded procedure for the installed automation identity, not a runtime,
worker, executor or administrator identity:

1. Read the exact AppId and enterprise-application ObjectId from the accepted
   deployment binding. Independently verify the enabled Entra service principal
   has both values. Do not substitute the app-registration ObjectId.
2. Use the official ExchangeOnlineManagement module in a real Windows
   administrator console. Prove the intended tenant, account and newly owned
   Security & Compliance session before reading or writing. Native broker
   authentication needs a real parent window; a headless window-handle error is
   not a reason to change execution policy or production executor authentication.
3. Read provider references and match both IDs exactly. An existing matching
   reference needs no create. A partial match, duplicate, denied read or malformed
   result must stop rather than be treated as absent.
4. Only after a successful read proves absence, record the exact one-create
   intent and use Microsoft's
   [New-ServicePrincipal](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-serviceprincipal?view=exchange-ps)
   with those AppId/ObjectId values. Do not create another Entra app, add guessed
   role grants, change a DLP policy or overwrite another environment's reference.
5. Read back the exact pair and verify unrelated references are unchanged. If
   the create response is lost, retain its intent and use readback only.
   Disconnect only the session opened for this work.

A registered reference is not a verified Gateway connection. Check the Gateway's
own app access next. A previously failed connection remains historical; a new
connection requires the normal separate review/confirmation flow. Do not alter
the failed job, reuse its expired helper result or make an unknown create repeat.

## Recovery principles

The [UX recovery scenarios](../docs/ux/acceptance-scenarios.md) define design and
regression targets for known failures and uncertain outcomes. The current Admin
UI preserves an external-ID recovery URL for an interrupted registration and
uses recorded-status or metadata reads after uncertain operations. Its
five-minute polling limit does not fail or cancel durable work. These client
actions do not widen authority, promise fresh provider reconciliation or permit
repeating an uncertain create.

Ordinary protection review IDs are durable operation IDs. Companion completion
has a separate approval but resumes the original reviewed connection ID. The UI
must receive browser acknowledgement of that execution/recovery ID before
confirmation/mutation and validate the returned ID. An old Submitted approval
may reference the original operation; follow only validated readback bindings.
After an uncertain result, read the original operation instead of creating new
consent, connection or policy work. Accepted companion launch instructions can be recovered
for the same actor without extending their original expiry. Runtime-test recovery
reads the safe report without replaying raw samples or treating cancellation as
proof that remote work did not occur.

- Diagnose and reconcile exact target state before a mutation.
- Preserve failed jobs, queue/dead-letter state, outbox rows, artifact digests and
  correlation evidence until the chosen recovery contract determines disposition.
- Reconcile an unknown external create outcome before considering any repeat.
- Treat broker settlement failure separately from workflow processing failure.
  Exhaustion must still match the current durable step/attempt generation;
  an older same-step publication cannot terminalize its replacement retry.
- Keep protection message producers and workers on a matching reviewed release.
  Legacy/unbound current messages require explicit reconciliation, not a fabricated
  zero generation or blind resubmission.
- Keep credentials, access tokens, authorization headers, clear Gateway keys and
  sensitive request bodies out of logs and diagnostics.
- Use a bounded recovery command only when state proves its eligible condition.
- Treat deliberately deleted resources as a fresh planning boundary, not an
  invitation to replay old deployment or incident state.

The [infrastructure index](../infrastructure/README.md) describes the declarative
inputs. The [API contract](../docs/api/api-contract.md) describes caller behavior.
