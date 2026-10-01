using Gateway.IntegrationTests.Fixtures;
using Gateway.TestSupport;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;

namespace Gateway.IntegrationTests;

[Collection(SqlServerCollection.Name)]
[Trait("Category", "SqlServer")]
public sealed class DatabaseSafetyTests(SqlServerFixture fixture)
{
    [Fact]
    public async Task Fixture_uses_real_SQL_Server_and_disposes_only_its_unique_database()
    {
        await using var database = await fixture.CreateDatabaseAsync();
        Assert.Matches(@"\Am1_test_[0-9a-f]{32}\z", database.Name);
        Assert.Matches(@"\Am1_test_[0-9a-f]{32}\z", fixture.InstanceName);
        LocalSqlConnectionGuard.Validate(database.ConnectionString, fixture.InstanceName, database.Name, fixture.PipeName);
        await using (var context = database.CreateContext())
        {
            Assert.Equal("Microsoft.EntityFrameworkCore.SqlServer", context.Database.ProviderName);
            Assert.Equal(1, await context.Database.SqlQueryRaw<int>(
                "SELECT CONVERT(int, SERVERPROPERTY('IsLocalDB')) AS [Value]").SingleAsync());
            Assert.Equal(database.Name, await context.Database.SqlQueryRaw<string>(
                "SELECT DB_NAME() AS [Value]").SingleAsync());
            Assert.True(new SqlConnectionStringBuilder(database.ConnectionString).IntegratedSecurity);
            Assert.True(await context.Database.CanConnectAsync());
        }
        await database.DisposeAsync();
        Assert.Throws<ObjectDisposedException>(() => database.CreateContext());
    }
}
