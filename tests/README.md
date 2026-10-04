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
reference checks against an existing deployment.

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
