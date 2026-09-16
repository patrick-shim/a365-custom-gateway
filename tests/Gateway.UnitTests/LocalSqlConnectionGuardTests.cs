using Gateway.TestSupport;
using Microsoft.Data.SqlClient;

namespace Gateway.UnitTests;

public sealed class LocalSqlConnectionGuardTests
{
    private const string Instance = "m1_test_11111111111141118111111111111111";
    private const string Database = "m1_test_22222222222242228222222222222222";

    [Fact]
    public void Generated_connection_is_explicit_unpooled_local_integrated_security()
    {
        var value = LocalSqlConnectionGuard.CreateConnectionString(Instance, Database);
        LocalSqlConnectionGuard.Validate(value, Instance, Database);
        var builder = new SqlConnectionStringBuilder(value);
        Assert.Equal($@"(localdb)\{Instance}", builder.DataSource);
        Assert.Equal(Database, builder.InitialCatalog);
        Assert.True(builder.IntegratedSecurity);
        Assert.False(builder.Pooling);
        Assert.Equal(0, builder.ConnectRetryCount);
        Assert.Empty(builder.UserID);
        Assert.Empty(builder.Password);
    }

    [Theory]
    [InlineData("production.database.windows.net")]
    [InlineData("tcp:production.database.windows.net,1433")]
    [InlineData("localhost")]
    [InlineData("127.0.0.1")]
    [InlineData(".")]
    [InlineData(@".\SQLEXPRESS")]
    [InlineData(@"(localdb)\MSSQLLocalDB")]
    [InlineData(@"(localdb)\m1_test_33333333333343338333333333333333")]
    [InlineData(@"np:\\.\pipe\LOCALDB\unowned")]
    public void Rejects_cloud_remote_loopback_shared_or_unowned_SQL(string source)
    {
        var builder = Valid();
        builder.DataSource = source;
        Assert.Throws<InvalidOperationException>(() =>
            LocalSqlConnectionGuard.Validate(builder.ConnectionString, Instance, Database));
    }

    [Theory]
    [InlineData("master")]
    [InlineData("existing_application")]
    [InlineData("m1_test_not-a-guid")]
    [InlineData("m1_test_22222222222242228222222222222222;DROP DATABASE master")]
    [InlineData("m1_test_33333333333343338333333333333333")]
    public void Rejects_non_owned_database_even_on_LocalDB(string catalog)
    {
        var builder = Valid();
        builder.InitialCatalog = catalog;
        Assert.Throws<InvalidOperationException>(() =>
            LocalSqlConnectionGuard.Validate(builder.ConnectionString, Instance, Database));
    }

    [Theory]
    [InlineData("Integrated Security", "false")]
    [InlineData("User ID", "synthetic-user")]
    [InlineData("Password", "not-a-real-password")]
    [InlineData("Authentication", "Active Directory Default")]
    [InlineData("AttachDBFilename", "unowned.mdf")]
    [InlineData("Failover Partner", "remote.invalid")]
    [InlineData("User Instance", "true")]
    [InlineData("Pooling", "true")]
    [InlineData("Persist Security Info", "true")]
    [InlineData("ConnectRetryCount", "1")]
    [InlineData("Connect Timeout", "0")]
    [InlineData("Application Intent", "ReadOnly")]
    public void Rejects_credential_resolution_failover_or_unbounded_connections(string key, string value)
    {
        var builder = Valid();
        builder[key] = value;
        Assert.Throws<InvalidOperationException>(() =>
            LocalSqlConnectionGuard.Validate(builder.ConnectionString, Instance, Database));
    }

    [Fact]
    public void Missing_connection_never_falls_back_to_host_configuration() =>
        Assert.Throws<InvalidOperationException>(() =>
            LocalSqlConnectionGuard.Validate(string.Empty, Instance, Database));

    [Fact]
    public void Only_the_exact_discovered_LocalDB_pipe_is_allowed_for_cross_architecture_hosts()
    {
        const string owned = @"np:\\.\pipe\LOCALDB#11223344\tsql\query";
        var connection = LocalSqlConnectionGuard.CreateConnectionString(Instance, Database, owned);
        LocalSqlConnectionGuard.Validate(connection, Instance, Database, owned);
        Assert.Throws<InvalidOperationException>(() =>
            LocalSqlConnectionGuard.Validate(connection, Instance, Database, @"np:\\.\pipe\LOCALDB#55667788\tsql\query"));
        Assert.Throws<InvalidOperationException>(() =>
            LocalSqlConnectionGuard.Validate(connection, Instance, Database));
    }

    [Theory]
    [InlineData(@"np:\\remote.invalid\pipe\LOCALDB#11223344\tsql\query")]
    [InlineData(@"np:\\127.0.0.1\pipe\LOCALDB#11223344\tsql\query")]
    [InlineData(@"np:\\.\pipe\sql\query")]
    [InlineData(@"tcp:remote.invalid,1433")]
    [InlineData(@"np:\\.\pipe\LOCALDB#11223344\tsql\query\other")]
    public void A_discovered_pipe_cannot_be_remote_or_an_arbitrary_SQL_pipe(string pipe) =>
        Assert.Throws<InvalidOperationException>(() =>
            LocalSqlConnectionGuard.CreateConnectionString(Instance, Database, pipe));

    private static SqlConnectionStringBuilder Valid() =>
        new(LocalSqlConnectionGuard.CreateConnectionString(Instance, Database));
}
