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

The returned provider responses are chosen fixtures, never live acceptance
evidence. Project acceptance remains solely in [MILESTONES.md](../../MILESTONES.md).
