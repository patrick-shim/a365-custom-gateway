# Repository validation

Run from the repository root with .NET 10, PowerShell 7, and the Console's Node
dependencies installed. These are executable regression projects, not a test-SDK
suite: use `dotnet run`, not `dotnet test`, to execute their assertions.

```powershell
dotnet build Gateway.slnx
pwsh -NoProfile -File tools/scripts/maintenance/Test-RepositoryLayout.ps1
npm --prefix web/console run check:reachability
npm --prefix web/console run typecheck
npm --prefix web/console test
dotnet run --project tests/Gateway.Agent365.RegressionTests
dotnet run --project tests/Gateway.Purview.Consumption.Tests
dotnet run --project tests/Gateway.RuntimeDataPlane.Tests
pwsh -NoProfile -File bootstrap/tests/SourceManifest.Tests.ps1
pwsh -NoProfile -File bootstrap/tests/Runtime.Assignment.Tests.ps1
pwsh -NoProfile -File bootstrap/tests/Runtime.Diagnostics.Tests.ps1
pwsh -NoProfile -File bootstrap/tests/Runtime.Purview.Tests.ps1
pwsh -NoProfile -File bootstrap/tests/Runtime.Retirement.Tests.ps1
pwsh -NoProfile -File bootstrap/tests/Runtime.Setup.Tests.ps1
pwsh -NoProfile -File bootstrap/tests/Runtime.Lifecycle.Tests.ps1
pwsh -NoProfile -File bootstrap/tests/Runtime.Apply.Tests.ps1
pwsh -NoProfile -File bootstrap/tests/Runtime.Context.Tests.ps1
dotnet run --project tests/Gateway.Setup.Tests
npm --prefix web/setup test
npm --prefix web/setup run build
```

## Standalone Purview authoring checks

The independent Purview authoring utility has offline behavior checks:

```powershell
pwsh -NoProfile -File tests/PowerShell/PurviewAgentDlp.Tests.ps1
```

These use synthetic provider responses and never connect to a tenant. They cover
preview/WhatIf, exact tenant/identity/SIT validation, preservation of existing
policies, and uncertain mutation/readback failures. Live policy creation,
distribution, allow/block, and sibling enforcement remain unverified until an
operator explicitly runs dedicated tenant tests.

## Manual Purview connector checks

`Gateway.Purview.Consumption.Tests` includes no-network checks for the local
manual-refresh implementation: idle listener behavior, authenticated commands and
results, wrong-key/tenant/replay rejection, monotonic checkpoints, provider
deadlines, exactly-once refresh consumption, assignment isolation, crash-window
command republication, transport cleanup eligibility, durable operation
submission, accepted-catalog reconciliation, `NeedsAttention`, and runtime
binding independence from display-catalog age. Backend checks also cover the
thirty-second authenticated-heartbeat boundary, retained-catalog degradation,
no-catalog disconnection, and liveness-only recovery without a provider read.

`bootstrap/tests/Runtime.Purview.Tests.ps1` verifies exact owned-task migration,
one bootstrap catalog read/publication, stable connector identity and transport
key, a single logon-only listener trigger, no periodic catalog action, and listener
restart settings without contacting a tenant. Console tests verify that status GET
and page mount create no operation, mutation headers are exact, duplicate actions
stay disabled, bounded polling stops, previous catalog state survives failure, and
assignment `NeedsAttention` is visible.

These checks validate source and simulated/local protocol behavior. They do not
claim a live tenant refresh, DLP propagation, normal allow, sensitive-data block,
same-blueprint sibling isolation, or downstream Agent 365/Purview/Defender
visibility. Use the explicitly gated live probe below for enforcement evidence.

## Live API documentation check

After rebuilding and starting the gateway:

```powershell
pwsh -NoProfile -File tools/scripts/diagnostics/Test-GatewayApiDocumentation.ps1
pwsh -NoProfile -File tools/scripts/diagnostics/Test-GatewayApiDocumentation.ps1 -BaseUri http://127.0.0.1:5081
```

These checks read the schema and reference without changing agent or policy state.

## Explicit integration tests

Set `GATEWAY_TEST_DB` to a PostgreSQL connection string supplied securely in the
environment, then run `tests/Gateway.RuntimeInfrastructure.Tests`. The role must
be able to create/drop databases. The test creates a random `gateway_audit_*`
database, performs every write there, then drops only that generated database in
`finally`. It never drops or modifies the supplied database. Optional
`GATEWAY_SCHEMA_AUDIT_DB` performs read-only model/column/constraint and orphan
reference checks against an existing deployment. The disposable-database checks
also force a dispatcher-versus-submission serializable conflict and verify bounded
recovery creates one connector operation and one audit event with exact idempotent
replay.

Set `GATEWAY_TEST_RABBITMQ` for the broker checks. They create random
`gateway-audit-*` queues, exercise real confirmations/retry/dead-letter settlement,
then remove only those generated queues. Production queue names are not used.

For the existing runtime data-plane regression, also pass an existing dedicated
test registration ID as the first argument. Its database writes are enclosed in a
rollback-only transaction. Consumption tests accept `GATEWAY_BINDING_TEST_AGENT`
for rollback-only assignment/receipt checks. Do not set the separately gated
`GATEWAY_SIBLING_API_TEST` except for a deliberately authorized live scope trial.

Missing integration configuration prints **skipped**, never a claimed live pass.
The explicit live Purview probe is
`tools/scripts/diagnostics/Test-GatewayAgentDlp.ps1`; it exits unsuccessfully unless
both the normal allow and DLP-specific sensitive block are observed.
