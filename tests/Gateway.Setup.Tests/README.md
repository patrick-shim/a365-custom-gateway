# Local Setup regression tests

Run from the repository root with the .NET SDK selected by `global.json`:

```powershell
dotnet restore tests\Gateway.Setup.Tests\Gateway.Setup.Tests.csproj
dotnet build tools\Gateway.Setup\Gateway.Setup.csproj --no-restore
dotnet test tests\Gateway.Setup.Tests\Gateway.Setup.Tests.csproj --no-restore
```

The suite covers public configuration round-tripping, capability validation,
exact reviewed Plan/Resume authorization, sanitized progress and completion
claims, exclusive process coordination, loopback sessions, and launcher arguments.
bUnit fixtures exercise empty, loading, error, confirmation and validation states.
Every test in this project is non-SQL; `--configuration Release --filter "Category!=SqlServer"`
runs the complete suite. Launcher boundary guards carry `Category=Guard`. SQL
transactional acceptance belongs to the separate parent-managed SQL test path.

Fresh Full/Core/Custom configurations all include shared Content Safety / Prompt
Shields infrastructure; per-agent use remains optional. Core omits Purview
prerequisites, not shared Prompt Shields. Synthetic legacy-disabled configurations
are preserved as recovery inputs and cannot authorize new configuration writes.

## Offline boundaries

- Component fixtures replace account discovery, Azure CLI, executable resolution,
  bootstrap processes, browser launch and configuration import before resolution.
  CLI/executable resolution and configuration writes fail if attempted. Tests
  assert that no live implementation remains registered at those boundaries.
- Process-coordinator tests use scripted process results. Parser tests use
  synthetic provider envelopes. Neither is evidence of a live deployment.
- File fixtures live under the test output directory in this checkout, are
  unique per test, and are deleted on disposal. They do not read the repository's
  ignored configuration, credentials, or `.bootstrap` checkpoints.
- Middleware tests use synthetic `DefaultHttpContext` requests and finite,
  in-memory sessions. No listener, real account discovery or full web-host
  startup is needed to verify nonce consumption, replay rejection and loopback
  authorization.
- Launcher process tests allow only help or a rejected argument, before host
  startup. The helper rejects commands that could start the web host, isolates
  the provider executable search path and CLI configuration paths, and stops
  each owned process by its exact handle in `finally`. `--no-open` is tested
  against the injected browser boundary. No shared browser, Azure CLI login,
  provider read, or bootstrap operation runs.

Root launchers and the full solution build are separate integration surfaces.
Project acceptance remains in [MILESTONES.md](../../MILESTONES.md); this document
does not establish deployment or milestone completion.

The [UX screen designs](../../docs/ux/screen-design.md) include the proposed
installation review/progress/handoff. Their synthetic browser fixture does not
start this Setup host or execute the bootstrap lifecycle.
