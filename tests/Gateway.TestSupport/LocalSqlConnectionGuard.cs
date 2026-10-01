using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;

namespace Gateway.TestSupport;

public static partial class LocalSqlConnectionGuard
{
    public static string CreateConnectionString(string instanceName, string databaseName, string? ownedPipe = null)
    {
        ValidateOwnedName(instanceName);
        ValidateOwnedName(databaseName);
        var builder = Build(instanceName, databaseName, ownedPipe);
        Validate(builder.ConnectionString, instanceName, databaseName, ownedPipe);
        return builder.ConnectionString;
    }

    public static void Validate(string connectionString, string instanceName, string databaseName, string? ownedPipe = null)
    {
        ValidateOwnedName(instanceName);
        ValidateOwnedName(databaseName);
        if (ownedPipe is not null)
            ValidateOwnedPipe(ownedPipe);
        var builder = new SqlConnectionStringBuilder(connectionString);
        if (builder.DataSource != (ownedPipe ?? $@"(localdb)\{instanceName}") ||
            builder.InitialCatalog != databaseName ||
            !builder.IntegratedSecurity ||
            builder.Authentication != SqlAuthenticationMethod.NotSpecified ||
            builder.UserID.Length != 0 || builder.Password.Length != 0 ||
            builder.AttachDBFilename.Length != 0 ||
            builder.FailoverPartner.Length != 0 ||
            builder.UserInstance || builder.PersistSecurityInfo ||
            builder.Pooling || builder.ConnectRetryCount != 0 ||
            builder.ConnectTimeout is <= 0 or > 30 ||
            builder.ApplicationIntent != ApplicationIntent.ReadWrite)
        {
            throw new InvalidOperationException(
                "Only the explicitly owned m1_test LocalDB database with integrated security is allowed.");
        }
    }

    internal static string MasterConnectionString(string instanceName, string ownedPipe)
    {
        ValidateOwnedName(instanceName);
        return Build(instanceName, "master", ownedPipe).ConnectionString;
    }

    internal static void ValidateOwnedName(string name)
    {
        if (!OwnedName().IsMatch(name))
            throw new InvalidOperationException("SQL test resources must be named m1_test_<32 lowercase GUID digits>.");
    }

    internal static void ValidateOwnedPipe(string pipe)
    {
        if (!LocalPipe().IsMatch(pipe))
            throw new InvalidOperationException("Only an exact machine-local LocalDB pipe is permitted.");
    }

    private static SqlConnectionStringBuilder Build(string instanceName, string databaseName, string? ownedPipe)
    {
        if (ownedPipe is not null)
            ValidateOwnedPipe(ownedPipe);
        return new()
        {
            DataSource = ownedPipe ?? $@"(localdb)\{instanceName}",
            InitialCatalog = databaseName,
            IntegratedSecurity = true,
            Pooling = false,
            ConnectRetryCount = 0,
            ConnectTimeout = 15,
            Encrypt = SqlConnectionEncryptOption.Optional,
            ApplicationName = "Gateway.M1.LocalSqlTests"
        };
    }

    [GeneratedRegex(@"\Am1_test_[0-9a-f]{32}\z", RegexOptions.CultureInvariant)]
    private static partial Regex OwnedName();

    [GeneratedRegex(@"\Anp:\\\\\.\\pipe\\LOCALDB#[0-9A-Fa-f]+\\tsql\\query\z", RegexOptions.CultureInvariant)]
    private static partial Regex LocalPipe();
}
