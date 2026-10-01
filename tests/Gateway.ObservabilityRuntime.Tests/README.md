# Offline worker and provider baseline

Run from the repository root with the SDK selected by `global.json`:

```powershell
dotnet restore .\tests\Gateway.ObservabilityRuntime.Tests\Gateway.ObservabilityRuntime.Tests.csproj --disable-parallel
dotnet build .\tests\Gateway.ObservabilityRuntime.Tests\Gateway.ObservabilityRuntime.Tests.csproj --no-restore --configuration Debug -m:1
dotnet test .\tests\Gateway.ObservabilityRuntime.Tests\Gateway.ObservabilityRuntime.Tests.csproj --no-build --no-restore --configuration Debug
```

The project references retained source projects, not historical binaries. Restore
can access package feeds; test execution does not require a deployed Gateway,
Azure, Microsoft Graph, Service Bus, SQL, environment credentials, or user secrets.

## Fixture boundaries

- `ScriptedTransport` is a terminal HTTP handler with an exact, finite request
  queue. It contains no socket handler, retry handler, redirect handler or default
  network fallback. Unregistered client names and unplanned/repeated requests
  throw. The official provider URI shapes are assertions, **not live targets**.
- All provider tokens are synthetic and supplied by finite scripts. Content
  Safety is constructed through its public DI registration, with its HTTP factory
  and `IPromptShieldTokenProvider` replaced before resolution. Typed registration
  supplies `new ManagedIdentityPromptShieldTokenProvider(Credential)` through the
  existing `TokenCredential` constructor seam. `Credential` is exclusively the
  finite `FixtureCredential`; no managed or ambient credential factory is used.
- Guard tests invoke the actual Prompt Shields, Purview, Agent 365 exporter and
  delegated Registry adapters against an empty transport script. Separate guards
  reject unknown client names, exhausted scripts and the managed-identity metadata
  endpoint. These prove this fixture boundary; they are not an OS network firewall
  for arbitrary newly added test code.
- `WorkerStore` serializes each successful `SaveChangesAsync` boundary and
  reopens independent entity instances. This checks handler recovery ordering,
  terminal redelivery, mirror claims, saved provisioning prefixes and delegated
  Registry handoff. It does **not** establish real SQL atomicity, concurrent-replica
  locking, Service Bus settlement or crash safety of the production repositories.
- Registry response loss is a simulated ambiguous POST followed by explicit,
  exact-ID readback; the fixture asserts no second POST. It does not run a signed-in
  administrator flow or prove preview-service behavior.
- The normal Purview evaluation fixture covers its existing bounded scope-refresh
  behavior. It does not run the approved-sample runtime probe, PowerShell executor,
  live policy propagation, role assignment or actual classifier enforcement.
- Release publication tests exercise the real package-publisher coordinator and
  Blob SDK adapter with the same terminal transport and synthetic credential.
  They assert create-only upload, exact ETag-bound readback, no mutation retry
  after response loss, rejection of conflicting bytes, and disabled provider
  logging. Executor caller tests cover the post-JWT application-only predicate;
  they do not replace signature validation or hosted Entra authorization.
- Settings failure fixtures preserve only safe inventory-expiry and proven
  transient-read-timeout classifications through the native adapter, executor
  dispatcher and client. Unknown mutation outcomes remain non-replayable.
  Reconciliation of absent, partial, mismatched or unknown provider state makes
  no create/update calls. The separate native
  [catalog tests](../LocalBaseline.Tests/PurviewCatalog.Tests.ps1) execute the
  authored script with isolated synthetic commands, checking one catalog per
  invocation, minimum imports and freshness immediately before writes.

The separate [Windows package qualifier](../../tools/Test-PurviewPackage.ps1)
extracts an already inspected content-addressed ZIP into an owned temporary
directory, runs its fixed native child probe and starts its actual executor with
synthetic identities. It sends only unauthenticated loopback health/execution
requests and verifies rejection. It does not load deployment configuration,
authenticate to Entra, execute a provider command or establish cloud networking.
Its signed runtime inputs are explicit and are not required by the default local
test runner.

The returned provider responses are chosen fixtures, never live acceptance
evidence. Project acceptance remains solely in [MILESTONES.md](../../MILESTONES.md).
