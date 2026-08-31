# Development deployment status

Last updated: 2026-08-31 (Asia/Seoul).

This checkpoint separates deployed evidence from source claims. It intentionally
contains no subscription, tenant, resource-group, application, principal,
registration, image-digest, correlation, credential, token, prompt, response, or
provider-body value. Environment-specific evidence belongs in ignored
`.bootstrap/` output or an access-controlled operator evidence store.

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

The next clean deployment is user-operated and must use a new deployment identity.
Do not point a fresh local bootstrap state at an existing resource group or reuse
state from a deleted resource group.

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
