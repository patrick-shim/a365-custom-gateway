using Microsoft.EntityFrameworkCore;

namespace Gateway.Infrastructure.Persistence;

public interface IDatabaseHealthProbe
{
    Task<bool> CanConnectAsync(CancellationToken cancellationToken = default);
}

internal sealed class DatabaseHealthProbe(GatewayDbContext dbContext)
    : IDatabaseHealthProbe
{
    public Task<bool> CanConnectAsync(CancellationToken cancellationToken = default) =>
        dbContext.Database.CanConnectAsync(cancellationToken);
}
