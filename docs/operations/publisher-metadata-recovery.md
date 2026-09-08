# Publisher metadata tooling reconciliation

Follow the [execution contract](../agent-guides/end-to-end-execution.md), the
[current continuation](../agent-continuation.md), and the
[deployment checkpoint](development-deployment-status.md). This is a bounded
operator recovery utility, not another installer or a general source upgrade.
Source tests and a local receipt do not complete deployment.

## Eligible boundary

The original deployment must retain fourteen completed stages, a failed Gateway
runtime deployment stage, an `Installing` executor record and a `Started`
publication intent. The publisher must have exactly one independently verified
successful execution. Incompatible recovery generations, altered configuration,
ownership, source, package, completed evidence or additional executions fail closed.

The diagnosed service response adds execution-only `imageType: ContainerImage`.
The corrected parser accepts only that exact discriminator; it rejects
`CloudBuild`, unknown values, null, malformed types and other unreviewed fields.
Image, environment, resources and the original raw publication intent remain exact.
The [BaseContainer schema](https://github.com/Azure/azure-rest-api-specs/blob/main/specification/app/resource-manager/Microsoft.App/ContainerApps/preview/2025-02-02-preview/CommonDefinitions.json)
documents the discriminator. The observed stable execution response includes it
even though the inspected execution schema omits it. This correction adds no
preview mutation API or alternate image source.

Never edit an accepted snapshot, reset the failed stage, rebuild the original
package, rotate a certificate, replay SQL or identities, or start the publisher
again to force progress.

## Read-only Plan

Use the original matching configuration and state in the canonical checkout,
with exact-target read authority:

```powershell
pwsh -NoProfile -File .\bootstrap\reconcile-publisher-metadata.ps1 -Mode Plan
```

Plan checks the exact operator, tenant, subscription, ownership and configuration;
original and corrected source manifests; original package; and independent
provider evidence. It hashes the **raw current job template**, job ID and intent ID
and compares that result with the original persisted publication-intent fingerprint
before accepting execution evidence. Current job/execution agreement alone is
insufficient.

Plan creates only new ignored review and immutable source-snapshot artifacts.
It leaves the original deployment state unchanged. Review its returned
`planFingerprint` and `planPath`; no receipt or deployment continuation is authorized
by merely producing a Plan.

## Receipt-only Execute

After explicit approval of that exact Plan:

```powershell
pwsh -NoProfile -File .\bootstrap\reconcile-publisher-metadata.ps1 `
  -Mode Execute -ExpectedPlanFingerprint '<reviewed sha256 fingerprint>' -Yes
```

Execute acquires the state lock, rereads and revalidates the original state,
source, package and provider evidence, then adds only a separate completion
receipt. It performs no provider mutation and does not advance the failed stage
or change publication from `Started`. Repeating the same approved completed
receipt is idempotent; changed evidence is not silently accepted.

## Normal Resume and verification

Only after receipt completion and authorization for the remaining deployment:

```powershell
.\gateway.cmd resume
.\gateway.cmd verify
```

The ordinary Setup read-only Resume review and separate confirmation are also
supported. Resume selects the corrected pinned tooling before callbacks while
retaining the original accepted source for Bicep, images, package and SQL assets.
The normal publication reconciler verifies the existing execution and checkpoints
it without another start. Normal remaining deployment steps then continue.

The receipt must remain valid through ordinary session revalidation and forward
progress; it never authorizes a different target, arbitrary source changes,
credential recovery, policy changes or completed-operation replay. On any failed
check, preserve the state, review artifacts and provider objects.

Verify all nineteen stages and the actual Admin UI endpoint before claiming
deployment success. Registry completion, verified Active registrations, Agent 365
landing and protection allow/block verdicts retain their separate live gates.
