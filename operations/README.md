# Gateway operations

Routine administration for an installed Gateway. Product objective, expected
behaviors, and UI platform (React + Fluent for all UIs; C# backend):
[product brief](../docs/spec/product-brief.md) ·
[UI design](../docs/console/design.md). Fresh install:
[bootstrap guide](../bootstrap/README.md). These commands use an explicitly
selected configuration and its preserved deployment state.

Hosted UI commands below still refer to the **Admin UI** while bootstrap deploys
Blazor; after Console cutover they target the React Console image instead.
`upgrade-admin-ui` is the transitional Admin UI-only promotion path.

| Command | Boundary |
|---|---|
| `gateway status` | Read local deployment state. |
| `gateway verify` | Read back current Azure, identity, database and endpoint bindings. |
| `gateway open` | Open the recorded verified hosted UI endpoint (Admin UI today; Console after cutover). |
| `gateway diagnose` | Create a bounded, sanitized diagnostic bundle. |
| `gateway resume` | Reconcile eligible interrupted work for the same accepted plan. |
| `gateway upgrade-admin-ui` | Perform a source-bound Admin UI-only promotion. |
| `gateway recover-database` | Reconcile an eligible interrupted database operation. |
| `gateway repair-database` | Run the exact reviewed database repair contract. |

On Windows use `.\gateway.cmd`; on macOS/Linux use `./gateway`.
Run `gateway --help` for arguments. Never edit a checkpoint to force progress,
reuse a deleted target or replay a create whose provider outcome is unknown.

## Supported implementation files

- [Provisioning preflight](verify-provisioning-prerequisites.ps1) is a read-only
  deployment prerequisite checker called by the canonical verifier.
- [Full maintenance](gateway-upgrade.ps1) supports Package, Prepare, reviewed
  Plan, Build, Execute and Verify, with bounded recovery and compatible rollback.
  Read the [upgrade contract](gateway-upgrade.md) before using it.
- [Admin UI promotion](upgrade-bootstrap-admin-ui.ps1) is called by the root
  launcher. Its readback helper preserves the verified predecessor separately
  from the original bootstrap image.
- [Windows package builder](build-purview-executor-package.ps1) is an installer
  dependency, not an alternative deployment path.
- `GatewayUpgrade*.psm1` and `GatewayAdminUiReadback.psm1` are internal modules.
  Do not run them as standalone repair scripts.

## Protection recovery

Registration, installed capability, saved policy, current enforcement and
telemetry delivery are separate states. Both protections Off is valid.

Read the exact saved operation before taking action. A completed historical
connection can have expired current readiness. A failed policy operation with
missing provider IDs does not prove no policy exists in Microsoft.

Connection refresh requires a fresh review and a fresh companion result.
**Review existing policy check** can reconcile the exact existing policy against
current inventory without repeating creation. It does not silently enable an
agent or renew earlier runtime proof.

### Purview automation reference prerequisite

The automation app's Entra service principal and its Security & Compliance
reference are separate prerequisites. A successful human sign-in or classifier
read does not establish the Gateway app's access. Settings must independently
verify the configured app, certificate and exact tenant binding. Do not register
another reference or broaden permissions merely to hide a failed read.

## Preservation and diagnostics

Ignored `.bootstrap/` and `.maintenance/` directories contain source-bound
operational journals, accepted inputs and immutable receipts. They are not
alternative source trees to develop in. Preserve the records needed by a live
installation and resolve uncertain provider outcomes by exact readback.

Keep passwords, tokens, ingress keys, raw prompts, responses and certificate
material out of logs and ordinary configuration. Capture bounded status,
operation IDs and safe source coordinates rather than raw provider bodies.

For API and protection semantics, see the [API contract](../docs/api/api-contract.md),
[protection architecture](../docs/architecture/protection-settings-plan.md) and
[Windows executor boundary](../docs/architecture/purview-windows-executor.md).
