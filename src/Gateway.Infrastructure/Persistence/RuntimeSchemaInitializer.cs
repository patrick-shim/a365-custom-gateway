using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Gateway.Infrastructure.Persistence;

internal sealed class RuntimeSchemaInitializer(
    IServiceScopeFactory scopeFactory,
    ILogger<RuntimeSchemaInitializer> logger) : IHostedService
{
    public async Task StartAsync(CancellationToken cancellationToken)
    {
        await using var scope = scopeFactory.CreateAsyncScope();
        var db = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        const string schemaLock = "a365gw:runtime:schema";
        await using var schemaConnection = await PostgresAdvisoryLock.AcquireSessionLockAsync(db, schemaLock, cancellationToken);
        try
        {
            await db.Database.EnsureCreatedAsync(cancellationToken);
            logger.LogInformation("Runtime PostgreSQL schema ensured.");
        }
        finally
        {
            await PostgresAdvisoryLock.ReleaseSessionLockAsync(schemaConnection, schemaLock, CancellationToken.None);
        }
    }

    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}
