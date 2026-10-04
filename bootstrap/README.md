# Runtime gateway bootstrap

Bootstrap installs the gateway on Docker Compose: PostgreSQL, RabbitMQ, Vault,
S3-compatible storage, the C# API and worker, and the React Console.
Microsoft Entra, Graph, Agent 365, Purview and Prompt Shields remain product APIs.

## Guided installation

Run `gateway.cmd init` on Windows or `./gateway init` elsewhere. `setup` is an
alias for this guided terminal flow. `gateway.cmd gui` (or `./gateway gui`) opens
the React installer in a browser on this computer. Keep its terminal open.
Review the generated non-secret configuration, then run `gateway plan` and
`gateway apply`, or use `gateway up` for the combined guided flow.

Every setup explicitly asks about Content Safety and the Purview connection.
Content Safety collects the subscription, region, resource group, SKU and cost
acknowledgement. Purview collects authorization for a dedicated certificate
identity and DLP management permissions, then provisions and verifies that access
under the Windows catalog-host account. No capability preset skips these choices.
Bootstrap does not collect SIT names or create policies, classifiers or rules.

When development Registry preview is explicitly enabled and acknowledged, bootstrap
also declares and grants exactly `AgentRegistration.Read.All` and
`AgentRegistration.ReadWrite.All` as delegated Graph permissions on the Gateway
API, then verifies the tenant-wide consent readback. Console sign-in alone cannot
grant these permissions. `gateway up` repairs an absent or incomplete grant for
the same owned API; unrelated permissions or ambiguous grants stop setup.

The seed blueprint's development credential is keyed by its application ID.
For Console-created blueprints, the worker verifies ownership, creates one
individual development credential and stores it under the ignored
`.bootstrap/secrets/blueprint-credentials` directory. The API mounts that directory
read-only. A missing saved credential requires explicit repair, never automatic
rotation. A seed secret must never be reused for another blueprint. Entra rejects
ordinary app tokens as AAD-issued federation assertions (`AADSTS700226`); local
runtime authentication does not pretend the workload app is a managed identity.

React Setup offers the same configuration fields, validation, reviewed plan,
provisioning, progress and verification through the same PowerShell engine. Its
local C# host uses a one-time link, session isolation and request validation.
No browser page performs its own cloud provisioning. Initial connection
setup must not be deferred to the Console; Settings contains ongoing diagnostics,
while policy selection and individual-agent assignment remain Console operations.

Configuration must explicitly select `deployProfile: runtime`. The
[example](config.example.runtime.json) documents fields; the
[schema](config.schema.json) rejects legacy profiles. Existing configuration and
credentials are preserved. Do not place tokens, passwords, private certificates,
Gateway keys, or prompt content in checked-in configuration.

## Commands

| Command | Behavior |
| --- | --- |
| `init`, `setup` | Guided terminal configuration |
| `gui` | React graphical configuration, plan, install and verification |
| `doctor` | Read-only runtime tools and product-session checks |
| `plan` | Review source-bound Compose and Microsoft product setup operations |
| `apply` | Apply the accepted plan for the exact current source/configuration |
| `up` | Configure if needed, plan, confirm, apply and verify |
| `status` | Read persisted runtime checkpoints; not a live readiness claim |
| `verify` | Check API, readiness, Console configuration and API proxy |
| `open` | Open the recorded Console endpoint |
| `diagnose` | Export sanitized diagnostics |

Known interrupted checkpoints are reconciled through exact ownership readback.
Concurrent terminal/GUI installers are blocked by one checkout lock. Missing
secrets, unexpected credentials or unknown checkpoints stop setup; credentials
are never silently rotated. No destroy command is provided.

## Validation

After the source checks pass, terminal acceptance uses:

```powershell
.\gateway.cmd init
.\gateway.cmd plan
.\gateway.cmd up
.\gateway.cmd verify
```

Graphical acceptance starts with `.\gateway.cmd gui`. Both interfaces use the
same engine. Live per-agent allow/block and sibling isolation must also pass;
installer health alone does not establish policy enforcement.

### Reviewed manager applications

Review the manager application IDs against Microsoft's current
[Agent 365 CLI authentication constants](https://github.com/microsoft/Agent365-devTools/blob/main/src/Microsoft.Agents.A365.DevTools.Cli/Constants/AuthenticationConstants.cs)
and read back the corresponding first-party service principal in the intended
tenant. Enter only the IDs reviewed for this deployment. Blueprint discovery alone
does not establish that an application should receive manager authority.
