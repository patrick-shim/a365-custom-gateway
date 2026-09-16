# Offline Admin UI baseline

Run from the repository root with the SDK selected by `global.json`:

```powershell
dotnet restore .\tests\Gateway.AdminUi.Tests\Gateway.AdminUi.Tests.csproj --disable-parallel
dotnet build .\tests\Gateway.AdminUi.Tests\Gateway.AdminUi.Tests.csproj --no-restore --configuration Debug -m:1
dotnet test .\tests\Gateway.AdminUi.Tests\Gateway.AdminUi.Tests.csproj --no-build --no-restore --configuration Debug
```

## Fixture boundaries

- bUnit renders the retained `Agents` page and `PurviewRuntimeTestPanel`, including
  their shared components. There is no running app host, browser, provider endpoint
  or authenticated tenant session.
- `ScriptedGatewayApi` permits only explicitly queued API invocations. Unexpected
  calls are recorded and throw, even if a component catches the exception.
  Completion assertions reject unused or unexpected calls. It has no real API
  client fallback.
- The default HTTP client, named client factory and access-token provider deny
  network/authentication attempts. Guard tests explicitly exercise these failures,
  including requests aimed at Microsoft providers and managed-identity metadata.
  Package restore is distinct from offline test execution.
- Pending responses use completion sources, not sleeps. Fixed synthetic identity
  and commitment values provide the protection context; unavailable/available
  fixtures do not depend on a short wall-clock timing window.
- `PrivateSampleRuntime` routes only the private-sample module import to finite
  `ScriptedJsObject` instances. `prepare` returns commitment metadata, not sample
  text. Unscripted `execute` calls throw. Cleanup calls have a bounded allowance.
  Ordinary Fluent UI display/focus interop uses bUnit's non-executing stubs.
- Role cases test rendered administrator actions, not server-side authorization.
  Stale saved versions, changed reviewed bindings and edited sample notifications
  require a fresh review/approval without executing a sample request.
- These are component-state and callback tests. They do not prove Chrome behavior,
  JavaScript hashing/erasure, real focus trapping, visual/accessibility acceptance,
  authentication, backend confirmation enforcement, or live protection behavior.
  The existing paging-unavailable wording is a baseline, not a pagination fix.

No fixture establishes milestone completion or live acceptance. See the sole
completion record, [MILESTONES.md](../../MILESTONES.md).
