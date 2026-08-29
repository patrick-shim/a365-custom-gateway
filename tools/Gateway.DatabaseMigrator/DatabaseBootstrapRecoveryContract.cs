namespace Gateway.DatabaseMigrator;

public enum DatabaseInitializationRecoveryMode
{
    Fresh,
    ResumeBeforeSchemaMutation,
    ResumeAfterSchemaCompleted
}

/// <summary>
/// Pure guards for the durable clean-database initialization boundary. The
/// database-level marker is written before EF performs its first table mutation.
/// </summary>
public static class DatabaseBootstrapRecoveryContract
{
    public const string MarkerName = "A365GatewayBootstrapInitializationIntent";

    public static void AssertPristine(PristineDatabaseSurfaceSnapshot surface)
    {
        ArgumentNullException.ThrowIfNull(surface);
        if (surface.UserTableCount != 0 ||
            surface.UnexpectedObjectCount != 0 ||
            surface.UnexpectedSchemaCount != 0 ||
            surface.UnexpectedPrincipalCount != 0 ||
            surface.RoleMembershipCount != 0 ||
            surface.UnexpectedDirectPermissionCount != 0 ||
            surface.UnsafeDatabaseOptionCount != 0 ||
            surface.DatabaseOwnerMismatchCount != 0)
        {
            throw new InvalidOperationException(
                "Clean bootstrap requires a pristine database surface before its durable initialization marker is written; unreviewed objects, schemas, authority, options, or ownership were found.");
        }
    }

    public static DatabaseInitializationRecoveryMode Classify(
        int userTableCount,
        string? observedMarker,
        string expectedMarker,
        bool exactCurrentSchema)
    {
        if (userTableCount < 0)
            throw new ArgumentOutOfRangeException(nameof(userTableCount));
        if (string.IsNullOrWhiteSpace(expectedMarker))
            throw new ArgumentException("The expected database initialization marker is required.", nameof(expectedMarker));

        if (observedMarker is null)
        {
            if (userTableCount != 0)
            {
                throw new InvalidOperationException(
                    "A nonempty Gateway database has no durable bootstrap initialization marker and cannot be adopted.");
            }

            return DatabaseInitializationRecoveryMode.Fresh;
        }

        if (!observedMarker.Equals(expectedMarker, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "The durable database initialization marker does not match this exact deployment ownership, source, server, and database.");
        }

        if (userTableCount == 0)
            return DatabaseInitializationRecoveryMode.ResumeBeforeSchemaMutation;

        if (!exactCurrentSchema)
        {
            throw new InvalidOperationException(
                "A marked Gateway database is nonempty but does not exactly match the current EF model; partial initialization is never continued automatically.");
        }

        return DatabaseInitializationRecoveryMode.ResumeAfterSchemaCompleted;
    }
}

public sealed record PristineDatabaseSurfaceSnapshot(
    int UserTableCount,
    int UnexpectedObjectCount,
    int UnexpectedSchemaCount,
    int UnexpectedPrincipalCount,
    int RoleMembershipCount,
    int UnexpectedDirectPermissionCount,
    int UnsafeDatabaseOptionCount,
    int DatabaseOwnerMismatchCount);

public sealed record ExpectedDatabasePrincipal(
    string Name,
    Guid ClientId,
    int ExpectedDirectPermissionCount);

public sealed record ObservedDatabasePrincipal(
    string Name,
    Guid? ClientId,
    string Type,
    IReadOnlyCollection<string> Roles,
    int DirectPermissionCount,
    int OwnedSchemaCount,
    int OwnedPrincipalCount);

public static class ExactDatabaseAuthorityContract
{
    private static readonly string[] ExpectedRuntimeRoles = ["db_datareader", "db_datawriter"];

    public static void AssertExactOrRecoverablePrefix(
        IReadOnlyCollection<ExpectedDatabasePrincipal> expected,
        IReadOnlyCollection<ObservedDatabasePrincipal> observed,
        string? recoverableIncompletePrincipalName,
        bool allowAllRecoverablePrefixes,
        bool requireAllExpectedPrincipals,
        int unexpectedRoleMembershipCount,
        int unexpectedDirectPermissionCount)
    {
        ArgumentNullException.ThrowIfNull(expected);
        ArgumentNullException.ThrowIfNull(observed);
        if (expected.Select(item => item.Name).Distinct(StringComparer.Ordinal).Count() != expected.Count ||
            expected.Select(item => item.ClientId).Distinct().Count() != expected.Count)
        {
            throw new InvalidOperationException("The reviewed runtime-principal contract contains duplicate names or client IDs.");
        }
        var expectedByName = expected.ToDictionary(item => item.Name, StringComparer.Ordinal);

        if (observed.Select(item => item.Name).Distinct(StringComparer.Ordinal).Count() != observed.Count ||
            observed.Any(item => !expectedByName.ContainsKey(item.Name)) ||
            unexpectedRoleMembershipCount != 0 ||
            unexpectedDirectPermissionCount != 0)
        {
            throw new InvalidOperationException("GatewayDb contains an unexpected principal, role membership, or direct permission.");
        }
        var observedByName = observed.ToDictionary(item => item.Name, StringComparer.Ordinal);

        foreach (var principal in observed)
        {
            var expectedPrincipal = expectedByName[principal.Name];
            var recoverablePrefixAllowed = allowAllRecoverablePrefixes ||
                principal.Name.Equals(recoverableIncompletePrincipalName, StringComparison.Ordinal);
            var directPermissionsAreExact =
                principal.DirectPermissionCount == expectedPrincipal.ExpectedDirectPermissionCount;
            var directPermissionsAreRecoverablePrefix = recoverablePrefixAllowed &&
                expectedPrincipal.ExpectedDirectPermissionCount == 1 &&
                principal.DirectPermissionCount == 0;
            if (principal.ClientId != expectedPrincipal.ClientId ||
                !principal.Type.Equals("E", StringComparison.Ordinal) ||
                (!directPermissionsAreExact && !directPermissionsAreRecoverablePrefix) ||
                principal.OwnedSchemaCount != 0 ||
                principal.OwnedPrincipalCount != 0)
            {
                throw new InvalidOperationException(
                    "A Gateway runtime principal does not have its exact reviewed Entra identity and authority boundary.");
            }

            var roles = principal.Roles.Order(StringComparer.Ordinal).ToArray();
            var rolesAreExact = roles.SequenceEqual(ExpectedRuntimeRoles, StringComparer.Ordinal);
            if ((!rolesAreExact && !recoverablePrefixAllowed) ||
                roles.Length != roles.Distinct(StringComparer.Ordinal).Count() ||
                roles.Except(ExpectedRuntimeRoles, StringComparer.Ordinal).Any())
            {
                throw new InvalidOperationException(
                    "A Gateway runtime principal has an unexpected or incomplete database-role contract.");
            }
        }

        if (requireAllExpectedPrincipals && expectedByName.Keys.Except(observedByName.Keys, StringComparer.Ordinal).Any())
        {
            throw new InvalidOperationException("One or more reviewed Gateway runtime principals are absent.");
        }
    }
}

/// <summary>
/// A canonical, provider-neutral projection of every relational schema surface
/// the clean bootstrap is authorized to create.
/// </summary>
public sealed record ExactDatabaseSchemaSnapshot(
    IReadOnlyCollection<string> Tables,
    IReadOnlyCollection<string> Columns,
    IReadOnlyCollection<string> PrimaryKeys,
    IReadOnlyCollection<string> UniqueConstraints,
    IReadOnlyCollection<string> ForeignKeys,
    IReadOnlyCollection<string> CheckConstraints,
    IReadOnlyCollection<string> Indexes,
    int UnexpectedSurfaceCount);

public static class ExactDatabaseSchemaContract
{
    public static void AssertExact(
        ExactDatabaseSchemaSnapshot expected,
        ExactDatabaseSchemaSnapshot actual)
    {
        ArgumentNullException.ThrowIfNull(expected);
        ArgumentNullException.ThrowIfNull(actual);

        if (!ExactSet(expected.Tables, actual.Tables) ||
            !ExactSet(expected.Columns, actual.Columns) ||
            !ExactSet(expected.PrimaryKeys, actual.PrimaryKeys) ||
            !ExactSet(expected.UniqueConstraints, actual.UniqueConstraints) ||
            !ExactSet(expected.ForeignKeys, actual.ForeignKeys) ||
            !ExactSet(expected.CheckConstraints, actual.CheckConstraints) ||
            !ExactSet(expected.Indexes, actual.Indexes) ||
            expected.UnexpectedSurfaceCount != actual.UnexpectedSurfaceCount ||
            actual.UnexpectedSurfaceCount != 0)
        {
            throw new InvalidOperationException(
                "GatewayDb does not exactly match the reviewed current EF relational model or contains an unreviewed database surface.");
        }
    }

    private static bool ExactSet(
        IReadOnlyCollection<string> expected,
        IReadOnlyCollection<string> actual)
    {
        var expectedValues = expected.Order(StringComparer.Ordinal).ToArray();
        var actualValues = actual.Order(StringComparer.Ordinal).ToArray();
        return expectedValues.Length == expectedValues.Distinct(StringComparer.Ordinal).Count() &&
               actualValues.Length == actualValues.Distinct(StringComparer.Ordinal).Count() &&
               expectedValues.SequenceEqual(actualValues, StringComparer.Ordinal);
    }
}
