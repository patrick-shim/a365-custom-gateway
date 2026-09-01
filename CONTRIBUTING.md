# Contributing to A365 Custom Gateway

Thank you for improving the Gateway. Changes must preserve its authorization,
identity, idempotency, recovery, and secret-handling boundaries.

## Before you change code

Start with the binding [repository agent instructions](AGENTS.md), then follow its
required reading order:

1. [Implementation status](docs/implementation-status.md)
2. [Agent continuation checkpoint](docs/agent-continuation.md)
3. [Repository architecture and safety rules](CLAUDE.md)
4. The relevant workstream guide:
   [Admin UI](docs/agent-guides/admin-ui.md) or
   [provisioning](docs/agent-guides/provisioning.md)
5. Before Azure, SQL, Entra, Service Bus, Graph, deployment, or incident work,
   [development deployment status](docs/operations/development-deployment-status.md)
   and the relevant runbook

Implemented code and tests are the primary contract. Validate Microsoft API,
permission, role, version, authentication, and preview claims against current
official Microsoft documentation before changing an integration.

## Local development

Install the .NET 10 SDK, PowerShell 7, Git, and Azure CLI. Local builds and tests do
not require or authorize a live tenant mutation.

```bash
dotnet restore src/A365Gateway.slnx
dotnet format src/A365Gateway.slnx --verify-no-changes
dotnet build src/A365Gateway.slnx -c Release --no-restore
```

Run the smallest affected test project first. The full .NET gate is:

```bash
dotnet test tests/Gateway.UnitTests -c Release
dotnet test tests/Gateway.AdminUi.Tests -c Release
dotnet test tests/Gateway.Setup.Tests -c Release
dotnet test tests/Gateway.ObservabilityRuntime.Tests -c Release
dotnet test tests/Gateway.IntegrationTests -c Release
dotnet test tests/Gateway.EndToEndTests -c Release
dotnet test tests/Gateway.ArchitectureTests -c Release
dotnet test tests/Gateway.SecurityTests -c Release
```

Bootstrap, Purview policy, and operations tests use Pester 5.6.1. The repository
source gate runs the appropriate suites:

```powershell
./tools/Test-BootstrapSource.ps1 -RunPester
```

Never point an automated test at a live tenant. A local green result is not
deployment evidence.

## Repository map

- `src/` — Gateway applications, contracts, domain, and provider integrations
- `tests/` — .NET, Pester, architecture, and security tests
- `bootstrap/` — clean-subscription configuration and orchestration
- `infrastructure/` — shared Bicep and ordered SQL assets
- `operations/` — reviewed existing-environment scripts
- `docs/` — public guides, runbooks, design records, and checkpoints

## Change expectations

- Keep the N:N registration contract: one stored registration, reusable blueprint,
  distinct child Agent ID, external ID, and one-time Gateway key lifecycle.
- Keep API authorization authoritative; UI checks are not a security boundary.
- Preserve RFC 9457 Problem Details, correlation IDs, claims challenges, SQL locks,
  outbox behavior, and redelivery-safe external mutations.
- Fail closed when a Microsoft capability is unknown, unauthorized, or unverified.
- Do not add a client-secret fallback where managed identity or federated identity
  is the reviewed contract.
- Do not log or persist credentials, tokens, authorization headers, raw prompts,
  responses, provider bodies, or clear Gateway keys.
- Add or update focused tests with every behavior change.
- Update durable documentation. Keep temporary debugging notes and live evidence in
  checkpoint or incident records, not public quickstarts.

## Pull request checklist

- [ ] The change is scoped and its user-facing outcome is described.
- [ ] Current Microsoft contracts were validated where relevant.
- [ ] Focused tests pass; broader affected gates were run.
- [ ] Release build and formatting pass, or the exception is documented.
- [ ] No secret, tenant content, or unsafe live identifier was added.
- [ ] Configuration, API, recovery, and documentation changes agree.
- [ ] The tracked continuation checkpoint names the exact unfinished action and
      live-action boundary for the next contributor.
- [ ] Any authorized live verification is recorded separately from local results.

Security issues should follow [SECURITY.md](SECURITY.md), not the public issue
tracker.
