# Clean-subscription bootstrap proof

This runbook defines the evidence required before the repository's day-zero path
may be described as live-proven. It does not authorize an Azure deployment,
Microsoft tenant mutation, paid SKU, canary, or cleanup. Obtain a named disposable
development subscription/resource group and explicit cost/tenant authorization
before `Apply`.

Do not target the evidence-bearing development resource group recorded in
[`development-deployment-status.md`](development-deployment-status.md). Never read,
replay, settle, attach, delete, or reinterpret any retained v1/v2/v3 message or
Registry artifact. Bootstrap has no destroy mode.

## 1. Record the authorization boundary

Record these safe values in the change record, not in source:

- approving person and approval time;
- disposable subscription ID, tenant ID, region, resource-group name, and project
  name;
- allowed spending/SKU boundary and expiry of the disposable environment;
- whether development Registry preview, Prompt Shields, or Purview is authorized;
- the administrators responsible for Azure role assignment, Entra/Graph consent,
  Agent ID, and optional Purview handoffs;
- the separately approved cleanup owner and procedure.

Never record a password, certificate value, access/refresh token, authorization
header, managed-identity assertion, Gateway key, prompt, response, or dependency
body. `bootstrap/config.json` contains public configuration only.

## 2. Prove source and workstation readiness

Use a clean checkout of the exact candidate commit:

```bash
./gateway doctor
pwsh ./tools/Test-BootstrapSource.ps1 -RunPester -CompileBicep
dotnet build src/A365Gateway.slnx -c Release
dotnet format src/A365Gateway.slnx --verify-no-changes
```

Run every test project directly as required by
[`../implementation-status.md`](../implementation-status.md). Record the commit,
zero-warning/error build, exact test totals, Pester total, Bicep total, and platform.
Do not copy a prior checkpoint's counts.

`doctor` must pass the deterministic tool/config/account gates. Any authority,
quota, region/SKU, licensing, Conditional Access, Purview propagation, browser,
first-agent, or canary item reported as `NotChecked` remains unproven; do not relabel
it as ready.

Local prerequisite installation is a mutation too. With installation enabled, the
bootstrap may install Git, Azure CLI, the .NET 10 SDK, or Bicep where supported,
and install the optional Exchange Online module for the current user. The bootstrap
doesn't require or invoke the Agent 365 CLI; it uses one reviewed Microsoft Graph
v1.0 blueprint create without creating a credential. If workstation changes
are outside the authorization, install the reviewed dependencies separately and
pass `--no-install` to `plan`, `up`, and `resume`.

## 3. Create and review configuration

Use `./gateway setup` (Windows: `gateway.cmd setup`) or `./gateway init`. Confirm:

- environment is `dev` and the project/resource-group identity is unique;
- the subscription and tenant match the approved disposable target;
- development Registry preview is off unless explicitly authorized;
- Prompt Shields and Purview are off unless separately authorized;
- paid S0 or other paid choices match the spending approval;
- no secret material appears in configuration or the generated diagnostic bundle;
- the ignored deployment state has a newly generated, unguessable ownership ID;
  same-name Entra applications without its exact ownership tags and pinned operator
  owner must stop as collisions rather than being adopted.

Run Plan and preserve only its safe result as an approval artifact:

```bash
plan_artifact="$(mktemp)"
./gateway plan --json --non-interactive | tee "$plan_artifact"
plan_fingerprint="$(jq -ser '[.[] | select(.planFingerprint? and .applyReady == true)] | if length == 1 then .[0].planFingerprint else error("expected one apply-ready plan") end' "$plan_artifact")"
```

The example uses `jq` supplied by the operator/CI environment; it is not a bootstrap
prerequisite. The approval record must include the artifact and this exact canonical
`sha256:` fingerprint. Never copy the value from a different commit, configuration,
target, or What-If run.

Plan must compile every Bicep entry point and complete authenticated
subscription-scope ARM What-If. Review its project-scoped deployment identity,
resource families, sorted change summary, imperative Entra/Graph/Agent 365/SQL/
policy manifest, cost classes, preview boundaries, administrator handoffs, and
explicitly unverified items. ARM What-If does not cover those imperative systems.
Also record the exact tenant, subscription, source fingerprint, and proposed SQL
bootstrap client IPv4 shown by Plan. The IPv4 is eligible only when bounded HTTPS
reads from ipify and AWS Check IP agree on the same canonical IPv4; it is included
in the descriptor and accepted plan fingerprint.

## 4. Apply through the exact accepted plan

Only after the recorded review, run the canonical flow interactively or through an
external approval gate:

```bash
./gateway up
```

For controlled non-interactive execution with an already established Microsoft
sign-in context, the external gate must return the exact reviewed value and the
executor must carry it into the recomputed plan:

```bash
: "${APPROVED_PLAN_FINGERPRINT:?external approval did not supply a plan fingerprint}"
test "$APPROVED_PLAN_FINGERPRINT" = "$plan_fingerprint"
./gateway up --json --non-interactive --yes \
  --expected-plan-fingerprint "$APPROVED_PLAN_FINGERPRINT"
```

`--yes` alone approves the plan freshly recomputed by `up`; it does not attest that
the earlier artifact was reviewed. The expected fingerprint is the external-review
binding, and bootstrap must reject any configuration, deployment-source, descriptor,
or sorted sanitized What-If change before mutation.

Plan acceptance must create an ignored content-addressed execution snapshot under
`.bootstrap/accepted-source/<ownership>/<plan>/`. Before Apply/Resume, confirm the
running checkout still has the exact accepted source fingerprint. Bootstrap then
validates that snapshot and loads mutation modules, templates, operational scripts,
project inputs, and the allowlisted ACR context from it. A missing, altered, or
out-of-bound snapshot is a hard stop. Once any durable step or output exists, the
same deployment state cannot be planned from a different source generation; do not
copy evidence between checkouts or edit its source metadata.

After Azure authentication, every Azure CLI mutation and readback must remain
explicitly pinned to the approved subscription, with the authenticated tenant and
subscription rechecked. Changing the CLI default subscription during a run must not
redirect a deployment or Graph operation.

If a step stops, preserve `.bootstrap` state, correct the named prerequisite, and
run `./gateway resume`. For controlled automation, obtain a newly reviewed Plan
fingerprint and pass it to Resume:

```bash
./gateway resume --json --non-interactive --yes \
  --expected-plan-fingerprint "$APPROVED_PLAN_FINGERPRINT"
```

Do not delete state, manually mark a step complete, or begin a second deployment
identity. A completed mutation checkpoint may be reused only after its independent
read-only validator succeeds. An unavailable or ambiguous readback must stop rather
than replay the mutation.

Empty-database initialization has a bounded, disclosed network mutation. Bootstrap
may temporarily enable the SQL public endpoint and creates exactly one deterministic
firewall rule whose start/end addresses equal the accepted Plan IPv4. Before doing
so it writes the ignored safe recovery record
`.bootstrap/evidence/<resource-group>/database/GatewayDb-network-recovery.json`.
Cleanup deletes the exact rule and reads back its absence, restores public access to
`Disabled`, and reads that state back. If either cleanup cannot be proven, the step
fails, the recovery record remains, and the same deployment must be resumed to
reconcile it; do not delete the record or create a second rule manually.

## 5. Verify the installed foundation

After Apply reports success, run:

```bash
./gateway verify
./gateway status
./gateway diagnose
```

Capture safe evidence for:

- project-scoped subscription/resource-group deployments and exact resource IDs;
- private-network posture and disabled local/key authentication where required;
- immutable API, worker, and Admin UI image digests, with the exact accepted source
  fingerprint in image evidence, ARM parameters/outputs, and deployed resource tags;
- project-scoped API/Admin applications, managed identities, exact roles, OBO FIC,
  and redirect URIs, including the state-owned application tags and single pinned
  operator owner;
- typed seed blueprint plus exact equality between provider-observed
  `managerApplications` and the independently reviewed one-to-ten IDs recorded in
  configuration and the accepted plan fingerprint;
- empty-database initialization, workload managed-identity principals, SQL public
  access restored to `Disabled`, exact temporary-rule absence, and cleared network
  recovery record;
- runtime/Admin health and provisioning-prerequisite readbacks;
- optional Content Safety account/role or Purview policy exact readback, including
  exact worker Purview environment settings and the narrowly scoped certificate
  read role when protection-profile provisioning is enabled;
- Key Vault Secrets User for the Admin UI user-assigned identity only on the exact
  Admin UI Entra client-secret resource, and—when enabled—for the worker only on
  the exact Purview certificate-secret resource; the API must have no shared-vault
  role.

Purview configuration readback is not propagation or verdict proof. A healthy
anonymous route is not authenticated control-plane proof. Local status must leave
First Agent Active and Canary Proven unverified until later evidence exists.

## 6. Run the bounded development proof

Use a newly issued registration only in the authorized disposable development
environment. Follow the current workflow-v3 and canary procedures referenced from
[`agent365-observability-setup.md`](agent365-observability-setup.md) and
[`purview-setup-runbook.md`](purview-setup-runbook.md). Required evidence is:

- one registration bound to one selected blueprint and one distinct child Agent ID;
- stage 1–5 worker completion and the user-only delegated Registry boundary when
  development preview is enabled;
- at most one Registry POST, persisted accepted ID, independent final verification,
  and `Active` at 100%;
- temporary Gateway key held only in memory and revoked in cleanup;
- a safe prompt evaluation followed by bounded activity and receipt-bound
  interaction acceptance, Agent 365 landing, and drained new v3 work, even when
  both optional prompt protections are disabled;
- when authorized, benign and synthetic-sensitive Purview results and/or Prompt
  Shields allow/block evidence, without raw prompt/response content.

The clean-bootstrap API publishes all four administrative roles for `User` members
only. Its bounded canary must therefore authenticate the assigned Gateway
Administrator as a user and request `{gatewayApiScopeBaseUri}/access_as_user`.
`Gateway.LiveCanary` supports this through `InteractiveBrowserUser` and a separately
reviewed, temporary public-client application with the exact loopback redirect. Do
not add `Application` to `Gateway.Administrator`, grant the Azure CLI delegated
consent as a workaround, or pass a bearer token on a command line. Remove the
temporary client application, service principal, and delegated grant after the
credential has been revoked, then rerun exact application and runtime verification.

Before this wrapper is authorized, the signed-in bootstrap operator's existing
Microsoft Graph delegated context must support the exact temporary-authority
operations. Application create/update/delete and service-principal create/delete
require `Application.ReadWrite.All`; adding the pinned operator as the sole
application owner also requires `Directory.Read.All`; principal-specific grant
create/delete requires `DelegatedPermissionGrant.ReadWrite.All`. The documented
higher-permission alternative is `Directory.ReadWrite.All`. The user must hold a
supported Entra role for every operation; `Application Administrator` or `Cloud
Application Administrator` is the least common role boundary across this sequence.
Do not begin the state machine and then broaden consent or activate a role as a
retry. Correct missing authority first and use a new reviewed canary registration.

The reviewed wrapper is `operations/invoke-bounded-user-canary.ps1`. It derives one
deterministic `PreChild` and `ChildArmed` application name from the registration ID.
Its `-ExpectPromptShieldEnabled` and `-ExpectPurviewEnabled` switches are expected-
configuration assertions, not feature toggles. Both default to false when omitted,
matching the recommended minimal bootstrap profile. The wrapper binds both values
as canonical lowercase `true` or `false` in durable state and passes both required
expectation arguments to the child; a mismatch with the registration's observed
decisions fails closed.

With both switches omitted, the child requires exact `Disabled` and
`PurviewDisabled` decisions for the safe evaluation, then still proves sanitized
activity/OTel acceptance and receipt-bound interaction acceptance. It does not send
the synthetic injection prompt and reports that the Prompt Shields block proof was
not attempted. This is valid baseline ingestion and credential-lifecycle evidence,
but it is not Prompt Shields or Purview enforcement evidence. Pass
`-ExpectPromptShieldEnabled` only for an exact registration where Prompt Shields is
enabled; only that profile runs and requires the synthetic injection-block proof.
Pass `-ExpectPurviewEnabled` only when Purview is enabled; it tightens the benign
evaluation to the reviewed nonblocking Purview decisions. Record a separate
authorized synthetic-sensitive Purview result before claiming Purview blocking.

Its ignored `.bootstrap/canary/` record contains safe identifiers only: exact target,
registration/user/application/principal/grant/key IDs, lifecycle timestamps, and
hashes of the wrapper, its four imported helper modules, and the complete recursive
Release canary runtime bundle. It never contains a token, clear Gateway key, prompt,
response, or provider body. The state is written with file flush plus atomic replace
while an exclusive bootstrap lock is held. PowerShell 7.0–7.4 JSON date
materialization is normalized back to the canonical persisted UTC-string contract
before validation, so the advertised PowerShell 7 floor supports Resume and
`RevokeOnly`.

Application create, owner add, service-principal create, delegated-grant create, and
the `ChildArmed` rename each have separate durable `Started` and observed stages.
Every `Started` marker is persisted before its one Graph mutation. Afterward that
operation is GET-only across the current process and every resume; an absent or
mismatched readback never causes a repeated POST or PATCH. Any nonterminal durable
state preserves the exact temporary authority, including failures during later
subscription or Graph validation. `ChildLaunchStarted` is persisted before process
creation. If launch or key issuance becomes ambiguous before an ID is observed, a
second Full launch is permanently forbidden and recovery is manual-only.

The safe issued key ID is persisted as `CredentialObserved` before its terminal line
is rendered. Rerun the same wrapper with that exact `-RecoveryCredentialId <key-id>`
to select `RevokeOnly`; arbitrary IDs and missing or mismatched state are rejected.
The child requires the issued and revoked response metadata to match the exact
registration and key, requires the delegated token's `azp` to match the temporary
public client, and renders only allowlisted decisions plus canonical correlation
IDs. The wrapper performs no second key issuance or Entra create call and removes
the temporary authority only after idempotent revocation succeeds. Each Entra
cleanup proves the recorded object ID absent through bounded exact GET/404
reconciliation; a filtered collection miss or a renamed application is never
accepted as absence. Successful Full or
RevokeOnly processing first persists an immutable `Completed` tombstone, which
forbids a later Full run; subsequent default invocation is cleanup-only for exact
leftovers. `Completed` proves that the exact observed key reached the idempotent
revocation boundary and that no further Full launch is allowed. It is not, by
itself, proof that the earlier data-plane assertions passed: a tombstone reached
through `RevokeOnly` after a failed Full child records safe lifecycle closure only.
Record the child result separately in the deployment evidence. If the state, bound
executable bytes, or key ID cannot be validated, preserve everything and use exact
reviewed manual recovery. Microsoft Graph active application deletion is
recoverable soft deletion for 30 days; this procedure never permanently deletes the
application.

An unknown Registry POST outcome is exact-GET recovery only and is never posted
again. Any mismatch or nonrecoverable ambiguity is manual-only.

## 7. Reconcile and publish the checkpoint

Update both implementation and deployment status documents with the exact candidate
commit, local gate totals, safe Azure/Entra/Agent 365 identifiers, image digests,
revisions, schema state, correlations, queue/outbox counts, policy scope, recovery
state, limitations, and next action. State explicitly whether the evidence proves
only development, whether staging/production remain closed, and which readiness
layers remain unverified.

This runbook and the current implementation describe a source-reviewed path only;
they are not evidence that a disposable clean-subscription Apply or canary has run.
Cleanup is a separate explicitly approved operation. Record what was removed and
its recovery implications; do not add a destroy path to bootstrap or use cleanup to
erase incident evidence.

The working tree also contains stricter runtime Purview authority handling: exact
persisted provider IDs and authorized application scope, typed mode/action/bypass
readback, bounded temporary PKCS#12 cleanup proof, and final policy revalidation
before a protected registration can become `Active`. That work is local and
unreleased. Do not claim it is deployed or live-proven from bootstrap/unit/Pester
results; it requires a separately authorized rollout and bounded canary.
