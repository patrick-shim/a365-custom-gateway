# Continuous development proof — 2026-08-28

This is a redacted, non-secret checkpoint. It contains no Gateway key, token,
assertion, authorization header, prompt, response, or dependency body.

## Deployed revisions

- API: `ca-gateway-api-dev--purviewguard-20260828222324`, digest
  `sha256:5275b3adcdb3e17f39e7b7466fc989bfeae04904f64f85226931be19c6e939b7`;
  health and readiness returned HTTP 200 with 100% traffic.
- Worker: `ca-gateway-worker-dev-vnet--rbacrefresh-202608282058`, digest
  `sha256:9dad873fe49b17c55677674688616c9770f8e3810c878702011632dda9dd7c9e`.
- Admin UI: `ca-gateway-admin-dev--continuous-202608282042`, digest
  `sha256:8a447f481294822141d550b9313c2bd3249dc1fea7430cefcc21f2a2ef1c876e`.

## Active mappings

Create-new blueprint path:

- external ID `agent-89a205c4340644debaf53248cfdfd8eb`;
- registration `fb35a5ce-8df5-48c2-86e9-9411d17df070`;
- blueprint `79a71594-6435-4c64-a7bf-5f472a475792`;
- child Agent ID `640f3b3a-1ff2-4ab5-b1a4-cfac59dd35de`;
- Registry ID `9451d70c-71b6-45eb-9db5-4be8f05c6d04`;
- completed retry operation `6395ab47-e6c8-4584-8867-36c5c09f9475`.

Reuse-existing blueprint path:

- external ID `agent-ef6f55ea1525406bb93997c2e8b771cd`;
- registration `ff685604-999c-4584-9cec-87ec21f870ee`;
- blueprint `29fa5cc5-c42b-4bdc-8f99-d85a5b91ad01`;
- child Agent ID `954fec63-53a7-4556-abaa-67acf11956c8`;
- Registry ID `b2bf22e4-3d2c-49b4-8ead-a003d2496dab`;
- completed operation `099248a5-e1a3-4c50-a456-d0a04a6f1933`.

Both records were visually verified as Available with platform A365CustomGateway in
Microsoft 365 Admin Center. The workflow-v3 queue was `0 active / 0 scheduled / 9
dead-letter`; retained workflow-v2 and historical queues remained `0/0/3` and
`0/0/2`. No retained message was accessed or changed.

## Blueprint-scoped Purview proof

Policy `A365 Tourist OBO Python DLP (OBS Gateway)` targets reusable blueprint
`29fa5cc5-c42b-4bdc-8f99-d85a5b91ad01`. The policy returned inline scope for
`uploadText` and offline scope for `downloadText`.

- benign correlation `de14f217-3380-42cb-9b9e-92df5a2e9ea7` returned HTTP 202 with
  `Accepted`, `AuditLogged`, and observability `Queued`;
- authorized synthetic sensitive correlation
  `0c882b36-efe9-444e-bf86-d1b4415ea455` returned HTTP 202 with `Failed`, `Blocked`,
  and observability `Pending`; no observability message was queued.

The protected policy application is the reusable blueprint. The child Agent ID and
blueprint remain in `aiAgentInfo` for attribution; the Gateway API managed identity
is the integrated caller. This supports one policy per reusable blueprint instead of
one policy per child Agent ID.

## Verification boundary

The local Release gate is 1,095/1,095 and the final API health/readiness checks pass.
The latest SQL artifact predates these registrations, so it must not be presented as
current SQL/outbox evidence. SQL finalization, staging multi-replica/failover, and
production rollout remain separate gates.
