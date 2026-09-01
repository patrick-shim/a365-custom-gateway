---
name: validate-microsoft-docs
description: Validate a Microsoft API, SDK, CLI, permission, role, or product capability against official Microsoft documentation before relying on it in the A365 Gateway.
---

# Validate Microsoft Documentation

Research Microsoft-specific capabilities before implementation. Do not infer an
API, permission, or supported authentication mode from product marketing, a code
comment, or the project specification.

## Contract boundary

Gateway-owned `/api/v1/*` routes are solution APIs, not Microsoft APIs. Validate
their behavior from implemented controllers/contracts and deployed OpenAPI, not
Microsoft Learn.

Follow the complete Required reading sequence in the binding `AGENTS.md` before
acting and read every required file completely. For provisioning,
`docs/agent-guides/provisioning.md` is the relevant guide and defines the safety and
ownership boundary.

## Workflow

1. State the exact capability to validate and the Microsoft product that owns it.
2. Search only current official Microsoft primary documentation.
3. Read the primary documentation page rather than relying on search snippets.
4. Record:
   - requirement;
   - official URL and relevant update/version context;
   - documented API, SDK, or CLI mechanism;
   - authentication mode;
   - exact delegated/application permissions and Entra/Azure roles;
   - GA/Preview/Private Preview status;
   - limitations and tenant/admin prerequisites;
   - implementation decision and unresolved questions.
5. Cross-check any time-sensitive permission, endpoint, SDK version, CLI argument,
   or preview claim immediately before implementation.
6. Update `docs/architecture/microsoft-capabilities.md` when documentation work is
   part of the requested change, and label prior conclusions that were superseded.

Useful official documentation families include:

- `https://learn.microsoft.com/microsoft-agent-365/`
- `https://learn.microsoft.com/entra/agent-id/`
- `https://learn.microsoft.com/graph/`
- `https://learn.microsoft.com/purview/developer/`
- `https://learn.microsoft.com/azure/key-vault/`
- `https://learn.microsoft.com/azure/service-bus-messaging/`

## Unsupported or unclear capabilities

- Do not fabricate REST endpoints, SDK calls, CLI commands, permission names, or
  application-only support.
- If only a delegated, CLI, preview, or administrator-mediated workflow is
  documented, model that real constraint explicitly.
- If current documentation supersedes an old “unsupported” or “manual approval”
  conclusion, correct the old conclusion everywhere it remains authoritative.
- If no supported mechanism can be verified, fail closed and document the gap
  rather than creating a working-looking stub.

## Validation record

Use a compact table such as:

```markdown
| Requirement | Official source | Mechanism | Auth mode | Permissions/roles | Status | Limitations | Decision |
|---|---|---|---|---|---|---|---|
```

Every Microsoft-specific production code path must be traceable to current official
evidence. Quote sparingly, cite the exact source, and distinguish documented fact
from project inference. Never access or copy `.secret` or `.secrets` while
validating docs.
