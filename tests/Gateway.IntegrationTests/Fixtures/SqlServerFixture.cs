using Gateway.TestSupport;

namespace Gateway.IntegrationTests.Fixtures;

[CollectionDefinition(Name)]
public sealed class SqlServerCollection : ICollectionFixture<SqlServerFixture>
{
    public const string Name = "Isolated SQL Server LocalDB";
}

public sealed class SqlServerFixture : IAsyncLifetime
{
    private LocalSqlInstance _instance = null!;
    public string InstanceName => _instance.Name;
    public string PipeName => _instance.PipeName;
    public async Task InitializeAsync() => _instance = await LocalSqlInstance.CreateAsync();
    public Task<LocalSqlDatabase> CreateDatabaseAsync() => _instance.CreateDatabaseAsync();
    public Task DisposeAsync() => _instance is null ? Task.CompletedTask : _instance.DisposeAsync().AsTask();
}
