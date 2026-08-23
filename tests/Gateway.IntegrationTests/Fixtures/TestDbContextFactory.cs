using Gateway.Infrastructure.Persistence;
using Microsoft.EntityFrameworkCore;

namespace Gateway.IntegrationTests.Fixtures;

internal static class TestDbContextFactory
{
    public static GatewayDbContext Create(string? databaseName = null)
    {
        var options = new DbContextOptionsBuilder<GatewayDbContext>()
            .UseInMemoryDatabase(databaseName ?? Guid.NewGuid().ToString())
            .Options;

        var context = new GatewayDbContext(options);
        context.Database.EnsureCreated();
        return context;
    }
}
