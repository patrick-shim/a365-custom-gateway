# Documentation

Start with the [project README](../README.md) for the public overview and setup,
the [technical specification](../SPEC.md) for normative requirements, and
[repository governance](../AGENTS.md) before implementation work.

| Guide | Contents |
| --- | --- |
| [Technical specification](../SPEC.md) | Implemented scope, architecture, flows, contracts, invariants and acceptance criteria |
| [vNext specification](../SPEC-VNEXT.md) | Approved future architecture, contracts, migration, milestones and release gates; implementation is on hold |
| [Repository governance](../AGENTS.md) | Implementation rules, security guardrails and definition of done |
| [Bootstrap](../bootstrap/README.md) | Shared terminal/React setup, tenant permissions and configuration |
| [Runtime](runtime/README.md) | Installation state, rebuilds and diagnostics |
| [API contract](api/api-contract.md) | Authentication, endpoints and integration semantics |
| [OpenAPI schema](api/openapi.yaml) | Generated request/response contract; live reference at `/docs` |
| [System architecture](architecture/system-architecture.md) | Components and authority boundaries |
| [Data model](architecture/data-model.md) | PostgreSQL persistence and invariants |
| [Purview policy consumption](architecture/purview-policy-consumption.md) | Existing-policy catalog and individual-agent scope |
| [Purview catalog host](architecture/purview-catalog-host.md) | Certificate management identity and authenticated transport |
| [Protection configuration](architecture/protection-configuration.md) | Feature settings, review and concurrency |
| [Microsoft capabilities](architecture/microsoft-capabilities.md) | Provider contracts and limitations |
| [Product brief](spec/product-brief.md) | Product responsibilities and boundaries |
| [Purview Connector vNext detail](spec/purview-connector-vnext.md) | Focused connector design supporting the root vNext release specification |
| [Console design](console/design.md) | UI structure and behavior |
| [Operations](../operations/README.md) | Runtime support and verification |
| [Tests](../tests/README.md) | Source checks and explicit integration tests |
