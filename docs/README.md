# Documentation

Start with the [project README](../README.md) for the public overview and setup,
the [technical specification](../SPEC.md) for normative requirements, and
[repository governance](../AGENTS.md) before implementation work.

| Guide | Contents |
| --- | --- |
| [Technical specification](../SPEC.md) | Implemented scope, architecture, flows, contracts, invariants and acceptance criteria |
| [vNext specification](../SPEC-VNEXT.md) | Implemented local manual-refresh architecture and release gates; server/cloud M6 remains on hold |
| [Repository governance](../AGENTS.md) | Implementation rules, security guardrails and definition of done |
| [Bootstrap](../bootstrap/README.md) | Shared terminal/React setup, tenant permissions and configuration |
| [Runtime](runtime/README.md) | Installation state, rebuilds and diagnostics |
| [API contract](api/api-contract.md) | Authentication, endpoints and integration semantics |
| [OpenAPI schema](api/openapi.yaml) | Generated request/response contract; live reference at `/docs` |
| [System architecture](architecture/system-architecture.md) | Components and authority boundaries |
| [Data model](architecture/data-model.md) | PostgreSQL persistence and invariants |
| [Purview policy consumption](architecture/purview-policy-consumption.md) | Existing-policy catalog and individual-agent scope |
| [Standalone Purview policy authoring](../tools/scripts/setup/purview-agent-dlp.md) | Local PowerShell creation of a new agent policy using existing SITs |
| [Purview catalog host](architecture/purview-catalog-host.md) | Certificate management identity and authenticated transport |
| [Protection configuration](architecture/protection-configuration.md) | Feature settings, review and concurrency |
| [Microsoft capabilities](architecture/microsoft-capabilities.md) | Provider contracts and limitations |
| [Product brief](spec/product-brief.md) | Product responsibilities and boundaries |
| [Manual Purview refresh design and verification](spec/purview-connector-vnext.md) | Implemented local scope, evidence separation, administrator operations, migration, tests, and remaining live-validation boundary |
| [Console design](console/design.md) | UI structure and behavior |
| [Minimal Python echo sample](../samples/echo-agent.py) | One-file, standard-library prompt evaluation against an existing registration |
| [Python Foundry/MCP weather agent sample](../samples/python-foundry-weather-agent/README.md) | Standalone Flask current-weather chat demo using the real Gateway, Foundry, MCP, and Open-Meteo flow |
| [Operations](../operations/README.md) | Runtime support and verification |
| [Tests](../tests/README.md) | Source checks and explicit integration tests |
