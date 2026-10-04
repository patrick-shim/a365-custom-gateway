# Docker Compose runtime

Bootstrap builds and starts the gateway with `.\gateway.cmd up` from the repository root. It collects Microsoft identity, Content Safety and Purview settings and writes ignored `.env.runtime` configuration. Follow the [runtime guide](../../docs/runtime/README.md) for installation state, rebuilds and troubleshooting.

| File | Purpose |
| --- | --- |
| `docker-compose.yml` | PostgreSQL, RabbitMQ, S3-compatible storage and Vault development services |
| `docker-compose.apps.yml` | API, worker and React Console |
| `.env.example` | Non-secret reference configuration |
| `.env.runtime` | Generated configuration and secrets; never commit |

Use both Compose files and the generated environment file for an existing installation:

```powershell
docker compose --env-file deploy/runtime/.env.runtime -f deploy/runtime/docker-compose.yml -f deploy/runtime/docker-compose.apps.yml up -d
```

Keep the configured Compose project name stable. Changing it creates a different stack and different named volumes. Default Console/API ports are 5081/5080 on loopback. The Console links to the [API reference](http://127.0.0.1:5081/docs).

This is a development topology with development service credentials and Vault development mode. Production deployments require TLS, secured durable secrets and infrastructure configuration appropriate to their environment. The Windows Purview certificate host is managed by bootstrap, outside Compose.

For local API debugging, `dotnet run --project src/Gateway.Api --launch-profile runtime` loads `appsettings.Runtime.json`; supply the deployment-specific identity and provider settings securely. Avoid running a second debugging worker against the active deployment's queue. See [validation](../../tests/README.md) for isolated database and broker tests.
