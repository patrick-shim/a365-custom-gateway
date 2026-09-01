# Development deployment status

Last updated: 2026-09-01 (Asia/Seoul).

This checkpoint separates deployed evidence from source claims. It intentionally
contains no subscription, tenant, resource-group, application, principal,
registration, image-digest, correlation, credential, token, prompt, response, or
provider-body value. Environment-specific evidence belongs in ignored
`.bootstrap/` output or an access-controlled operator evidence store.

For unfinished source work after a fetch, pull, or fresh clone, begin with the
tracked [agent continuation checkpoint](../agent-continuation.md). Git alone does
not transfer the ignored state required to Resume an existing deployment.

## What has been verified in a clean subscription

An internal development deployment verified the audience bootstrap path through:

- one bootstrap-owned Azure resource group;
- Azure SQL initialized with Microsoft Entra authentication only;
- immutable API, worker, and Admin UI images;
- healthy API readiness endpoints and working Admin UI sign-in;
- the current seven-step provisioning workflow and one Active registration;
- one accepted Agent 365 activity; and
- resumable recovery after a stale final provider read, without another Registry
  POST.

Those observations prove the deployed build that produced them. They do not prove
that later source changes are deployed.

## Relationship to the current source tree

The checked-out source uses the root `gateway` launcher, one clean-subscription
bootstrap, the fixed Know Your Data Group location, and blueprint-specific DLP
Individual locations. A source revision is not deployed evidence until immutable
image digests, exact resource readbacks, health checks, queue state, and a bounded
first registration are recorded for that revision.

The current source correction adds a dedicated checkpoint-aware Resume path,
post-lock state reread and started-Apply routing, exact subscription binding for
secure ARM mutations, and one management-plane-only Admin UI credential transfer
for a private vault. It also adds Windows prerequisite repair and hosted Windows
Bicep compilation coverage. None of those source changes has been deployed or
live-verified at this checkpoint.

The next clean deployment is user-operated and must use a new deployment identity.
Do not point a fresh local bootstrap state at an existing resource group or reuse
state from a deleted resource group.

## Current user-operated clean-subscription checkpoint

The interrupted clean-subscription target remains stopped and untouched during this
pause. Its resource group was not deleted, no tenant object was removed, and no new
Azure, Entra, SQL, Graph, Service Bus, Purview, or deployment call was made while
preparing this checkpoint. That target is not current-source deployment evidence.

Before a later clean run, an operator must re-establish the exact authorized tenant
and subscription boundary, verify the stopped disposable target, delete only that
reviewed target, and prove exact absence. The next bootstrap must then use a new
unused deployment identity; preserved state from the stopped target must not be
forced into another resource group.

The next run starts from a new unused deployment identity and selects Korea Central
through the subscription-backed Setup dropdown, which persists `koreacentral`.
Doctor and Plan must prove the exact configured Azure SQL path in that region before
any mutation. The resulting source/configuration/plan fingerprints and deployed
readbacks become the new environment evidence only after verification completes.

## Paused source checkpoint

The backend Resume contract is implemented and has focused offline coverage:

- a started `Up` or explicit `Apply` is routed from state reread under the lock;
- every completed checkpoint is independently revalidated without another Plan;
- a read-only non-interactive review emits the preserved accepted-Plan fingerprint
  and one checkpoint-bound Resume authorization fingerprint without mutation;
- confirmed non-interactive Resume requires both exact fingerprints and rejects a
  changed current record before any remaining deployment step;
- secure ARM deployments require the canonical configured subscription; and
- private-vault Admin UI credential transfer uses one secure ARM child resource,
  no Key Vault data-plane authority, no value output, and value-free exact readback.

The combined Resume and Azure regression suite passed 323 of 323 tests. Entra
credential and orphan-cleanup coverage passed 33 of 33; Windows Bicep prerequisite
coverage passed 9 of 9; the Windows Azure CLI boundary passed 8 of 8; and the source
compiler passed 10 of 10, parsed 18 PowerShell files and two JSON contracts, and
compiled 27 Bicep templates plus three parameter files locally through the explicit
Windows Bicep compilation lane. The complete bootstrap Pester set passed 741 tests
on Windows with zero failures and seven skips. All eight .NET test projects passed
1,681 tests, and the Release solution build completed with zero warnings and zero
errors. Launcher coverage executed 11 tests on Windows and skipped six non-Windows
cases as designed.

The backend source in this checkpoint passed a final hash-scoped security rereview:
356 focused tests passed and all four prior Resume/private-vault findings were
closed. It has not completed hosted Windows launcher execution, browser testing, or
live deployment. Setup's ephemeral two-step Resume review and confirmation
service/UI integration is now implemented, tested, and rereviewed; what remains for
that area is fixture-backed browser inspection over preserved stopped state, so a
restarted Setup process is still not claimed as end-to-end Resume recovery.

## Optional protection evidence

Prompt Shields reached Azure AI Content Safety successfully in the internal
development environment. The combined Prompt Shields plus Purview request then
failed closed at the Purview dependency.

Directory readback showed the intended Purview Graph app-role assignments, but a
safe in-memory check showed that the managed-identity token did not yet contain the
required Purview roles. No token was printed or persisted. Therefore:

- policy-object readback is configuration evidence only;
- directory role assignment is not token-role evidence;
- the current source correctly keeps `Purview__Enabled=false` during bootstrap;
- Purview runtime readiness requires a fresh managed-identity token-role check and
  a bounded allow/block request; and
- the repository does not claim response-side inline DLP enforcement.

Follow the [Purview runbook](purview-setup-runbook.md) for the post-bootstrap
configuration and validation boundary.

## Live-action boundary

- Do not mutate or delete the stopped disposable target until the user returns and
  reauthorizes continuation after reviewing this pause commit.
- Do not run a new bootstrap against the preserved internal development resource
  group or adopt it from a new local state directory.
- Do not access, replay, or dispose of retained dead-letter evidence without a
  separately authorized incident procedure.
- Do not expose or attempt to recover a one-time Gateway key.
- Do not describe current source as deployed until its own readbacks are recorded.
- Do not enable Purview runtime enforcement merely because directory assignments
  or policy objects exist.

## Evidence required after a future deployment

Record environment-specific details outside the public repository, then summarize
only the non-sensitive outcome here:

1. accepted source/configuration/plan fingerprints;
2. immutable deployed image digests and active revisions;
3. exact identity, role, federation, network, and database readbacks;
4. API and Admin UI health;
5. active/scheduled/dead-letter counts for every owned queue;
6. one bounded registration through `Active` without duplicate Registry mutation;
7. optional Prompt Shields and Purview results, clearly separated; and
8. the next safe operator action.

The durable deployment lessons are reflected in code and runbooks: private SQL
requires private execution reachability, ACR pull identity must exist before first
workload pull, an empty database is the only automatic initialization target,
unknown Registry POST outcomes are GET-only, and optional protection readiness
must not close the core registration path.
