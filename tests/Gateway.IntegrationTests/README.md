# Local SQL behavioral tests

Run from the repository root with the repository-pinned .NET SDK:

```powershell
dotnet test tests\Gateway.UnitTests\Gateway.UnitTests.csproj --configuration Release --nologo --filter 'Category!=SqlServer'
dotnet test tests\Gateway.IntegrationTests\Gateway.IntegrationTests.csproj --configuration Release --nologo --filter 'Category=SqlServer'
```

These are separate test projects. The unit project does not start SQL Server.
Every integration test is explicitly tagged `Category=SqlServer`. A missing SQL
prerequisite **fails** the SQL fixture; it is never silently skipped or replaced
with an InMemory/SQLite database.

The normal baseline excludes this dedicated integration project entirely. The
unit project covers the connection guard without starting SQL. An explicit SQL
run must select `Category=SqlServer` in this project and execute a nonzero number
of tests; an empty selection is not verification. The parent runner invokes this
project only with `-IncludeSql` and requires all tests to pass with none skipped.

## SQL prerequisites and isolation

- Windows and SQL Server 2022 LocalDB v16, with `SqlLocalDB.exe` at
  `C:\Program Files\Microsoft SQL Server\160\Tools\Binn\SqlLocalDB.exe`.
- Permission to create an instance owned by the current Windows user and write
  test output beneath the test process's current project directory.
- The fixture creates a private `m1_test_<GUID>` instance and a fresh
  `m1_test_<GUID>` database for each test. It never opens an existing application
  database or starts/stops a shared instance.
- Connections use integrated security, no credentials, no pooling and bounded
  timeouts. The exact machine-local named pipe is discovered by calling
  `SqlLocalDB info` **only for the just-created instance**. This also supports an
  ARM64 .NET test host with the installed x64 LocalDB runtime.
- The connection guard rejects remote/cloud servers, loopback TCP, arbitrary
  named pipes, shared instances, another database, authentication providers,
  passwords, attached files and failover partners. Connection strings are never
  taken from environment variables, host configuration or repository settings.
- Database data/log files are created in a GUID-owned relative `TestResults`
  directory. Disposal drops and checks absence of each owned database, removes
  its directory, then stops/deletes only the fixture's private instance. A cleanup
  failure fails the run. Do not terminate the test runner during SQL cleanup.

The fixture creates the **current EF SQL Server schema** with `EnsureCreated`;
this is not migration-upgrade or production deployment validation.

## Implementation and provider boundaries

Registration, credential management, prompt evaluation/ingestion, idempotency,
protection readiness and persistence use the current handlers, repositories,
`GatewayDbContext`, `UnitOfWork`, cryptography and SQL constraints. No repository
or transaction implementation is mocked. Concurrent cases wait on real SQL
application locks or coordinate at a fake provider boundary, rather than claiming
thread locks simulate SQL transactions.

The only substituted services are blueprint catalog, Prompt Shields, Purview,
content storage, HTTP transport and token acquisition. They reject unscripted
calls by default. Scripted transports have a one-call budget unless the test
explicitly grants a larger finite budget; synthetic token acquisition is also
one-shot. Excess calls fail instead of falling back to live transport.
Tests construct their dependencies explicitly and never start
production host dependency injection or resolve ambient Azure credentials. The
real Content Safety client is exercised with an HTTP handler that cannot open
sockets and explicitly synthetic tokens. Production transport is never used.

Rollback tests inject an actual SQL check-constraint failure after staging work.
Receipt races use separate contexts/connections: same-key requests replay one
commit, different-key requests compete for one receipt and compensate only the
known rejected content stage. An arbitrary failed ingestion commit may leave a
staged provider object; the tests intentionally do not claim that the current
handler compensates uncertain outcomes.

Coverage is bounded to local implementation behavior. It does not establish live
Graph/Registry/Purview/Content Safety correctness, hosted authentication, migration
compatibility, cross-machine failover, simultaneous last-credential revocation,
browser journeys, worker recovery or sample model-callback execution. Those
require their separate acceptance scenarios. Paging/search behavior is outside
this baseline suite. Transactional ingestion scenarios supply explicit
idempotency keys; the optional-key HTTP contract is not exercised here.

For shared SQL tests reference `Gateway.TestSupport`, then use:

```csharp
using Gateway.TestSupport;

await using var instance = await LocalSqlInstance.CreateAsync();
await using var database = await instance.CreateDatabaseAsync();
await using var context = database.CreateContext();
```

Dispose all contexts/leases before their database, and the database before its
instance. Never add configurable connection strings or fallback providers to
this fixture.
