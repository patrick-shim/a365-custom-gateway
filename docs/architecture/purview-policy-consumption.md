# Individual-agent Purview policy consumption

Product boundary: policy owners author in Purview; gateway administrators select
existing compatible policies and assign individual agent identities.

## Console structure

- Agents: registration and details; separate Prompt Shields, Data protection,
  Identity, API key, and Activity tabs.
- Data protection: Policies, existing-policy discovery, individual-agent
  assignment, and enforcement evidence. No classifier or policy-rule editor.
- Settings: Gateway settings and Purview connection diagnostics.
- Bootstrap: tenant integration setup and first verification; each new agent's
  runtime permissions are checked when registration/protection makes them relevant.

Implementation must preserve this structure. Review catalog source, exact scope,
readback, failure states, and runtime evidence together before declaring completion.

## Product boundary

Purview policy owners own classifiers, rules, thresholds, actions, and policy mode.
Gateway administrators discover existing compatible DLP policies and assign them
to agents. Assignment may add a target to an existing policy; it must preserve
the policy definition and all existing inclusions/exclusions. It must never
silently widen an individual-agent selection to the agent's blueprint.

The policy catalog must come from Purview, not just the gateway's saved profiles.
Policies that are disabled, unsupported, or not scoped to the agent must have
explicit status. Selecting a policy does not exclude other applicable policies.

## Bootstrap and runtime responsibilities

Both terminal and React setup
collect all initial Purview connection settings and Content Safety provisioning
choices. Bootstrap provisions the dedicated certificate identity, required tenant
permissions, and selected Azure product resources, and verifies access. The two
interfaces must use one configuration and execution engine. This is an acceptance
requirement. The React replacement now uses the shared runtime engine, with
automated session/request-security tests and browser layout checks. User acceptance
and fresh agent enforcement trials remain distinct from installer health.

Show Content Safety and Purview as explicit, independent choices for every setup.
Explain the selected subscription, region, resource group, SKU, certificate host,
identity and permission changes in the reviewed plan. Settings in the Console
shows ongoing connection diagnostics; it is not a second initial-setup wizard.
No bootstrap surface creates classifiers, sensitive information types, DLP rules,
or DLP policies. Existing-policy selection and exact per-agent assignment remain
Console operations after tenant setup succeeds.

Move tenant integration setup and initial verification into bootstrap. Keep
connection diagnostics under Settings; routine agent administration should not
require manually refreshing a connection every 15 minutes.

There are two independent permission paths:

* Management: read existing policy definitions and narrowly update their scopes
  through Security & Compliance PowerShell. Use a supported unattended identity
  provisioned by bootstrap.
* Runtime: authenticate to Microsoft Graph, compute protection scopes, and call
  `processContent`. This does not require an open PowerShell session. The agent
  calls the gateway's `POST /api/v1/prompts:evaluate`; the gateway calls Graph and
  enforces the returned actions before the external model runs.

Bootstrap prepares the tenant integration. Agent identity permissions must also
be checked when an agent is registered or protection is enabled, because that
identity may not exist at bootstrap time. Runtime tokens refresh automatically.
Policy state uses Graph scope/ETag change detection and background reconciliation.
Management inventory freshness and runtime readiness need separate state; do not
remove existing readiness gates without replacing their protections.

### Runtime implementation

The source includes a read-only catalog API and certificate publisher that read
existing DLP policies and application rules from Purview. Catalog validation
requires the exact tenant, a bounded complete list, unique IDs, definition
revisions, and a snapshot no older than five minutes. A compatible candidate
requires enabled Application-plane upload-text blocking; compatibility alone is
not assignment or enforcement proof. Read-only catalog authorization is separate
from mutation authorization.

The runtime deployment now uses a C# Windows catalog publisher. It connects with
the dedicated certificate, validates the actual connected tenant, reads policies,
and signs the bounded catalog with a domain-separated RSA signature. The API reads
an atomic snapshot through a read-only shared directory, pins the public certificate
from bootstrap configuration, and rejects tampering, wrong tenants, expired
certificates, and stale data. Failed refreshes do not publish successful empty data.
No management private key or administrator token is copied to the Linux API.
This is the local Compose transport; a production Windows service lifecycle and
managed shared storage remain deployment work.

The runtime bootstrap provisions a separate management application and a Windows
certificate, then verifies unattended access through a dedicated DLP role group.
No Entra Compliance
Administrator role is granted by the new path. Agent runtime tokens use a separate FMI exchange,
with tests proving child-identity and Graph/OTel token caches cannot collide.

The individual-agent path now has durable `AgentPolicyAssignments` reviews and
operations. Confirmation binds the administrator, tenant, registration protection
revision, child identity, blueprint relationship, policy ID, and canonical provider
revision. It immediately requests enforcement; unavailable assignment evidence
cannot issue a prompt receipt. Additional selected policies accumulate. Scope
removal and policy authoring remain in Purview.

The API verifies the child relationship and provisions only its two Graph runtime
roles (`Content.Process.User` and `ProtectionScopes.Compute.User`). Assignment
requests and results use separate HMAC domains and exact operation/tenant/target
bindings in a bounded atomic file queue. Bootstrap installs the random transport
key outside that queue. The Windows certificate host reads the current policy,
checks its reviewed revision, applies only `AddInclusions` to the child application
location if absent, and verifies the scope. Existing exclusions/narrow inclusions
cause conflict. Unknown mutation outcomes do not become successful assignments.

Nested SCC hashtables have nondeterministic enumeration order. Policy revisions
canonicalize their keys (and parsed Locations/AdvancedRule JSON) before hashing.
Real rule, mode, or scope changes still invalidate a review or runtime binding.
A policy change requires a new review; the gateway fails closed in the meantime.

Runtime uses the exact child's FMI token and application location. Scope caches
include the child, user, and blueprint; Graph and OTel token caches are separate.
The readiness path uses confirmed assignment plus the current signed policy
snapshot. It does not substitute catalog compatibility for runtime certification. Each prompt must still receive an inline Purview verdict.
Receipts bind the agent protection revision and individual assignment evidence;
changed/expired evidence prevents issuance and consumption.

The Console shows Applying assignment, Assigned/awaiting gateway verification,
Gateway allow and block verified, and Assignment not confirmed separately. The
last state is based on actual prompt-evaluation records for the current agent
configuration, not on a successful scope write. It does not attribute a verdict
to one selected policy when other policies may also apply.

## Enforcement verification

1. Read the selected policy and confirm compatibility.
2. Review and confirm the exact individual identity. Check fresh scope readback and preservation of unrelated targets and exclusions.
3. Call the gateway API with a normal prompt and require a valid allow receipt; send a synthetic sensitive prompt and require a DLP-specific block without a receipt.
4. Test a same-blueprint sibling with the same user and input. Check its own protection scope as well as the policy's locations; other applicable policies can affect its result.
5. Check ingestion and destination visibility independently. A local allow/block observation does not prove telemetry delivery.

## References

* [Graph processContent](https://learn.microsoft.com/en-us/graph/api/userdatasecurityandgovernance-processcontent?view=graph-rest-1.0)
* [Set-DlpCompliancePolicy Locations](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-dlpcompliancepolicy?view=exchange-ps#-locations)
* [Purview API integration](https://learn.microsoft.com/en-us/purview/developer/use-the-api)
