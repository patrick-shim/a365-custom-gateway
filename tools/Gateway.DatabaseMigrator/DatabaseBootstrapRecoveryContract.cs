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
        ArgumentNullException.ThrowIfNull(surface.CatalogSurface);
        ArgumentNullException.ThrowIfNull(surface.DirectPermissions);
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
                "Clean bootstrap requires a pristine database surface before its durable initialization marker is written; " +
                $"safe counts were tables={surface.UserTableCount}, objects={surface.UnexpectedObjectCount}, " +
                $"catalog=[{surface.CatalogSurface.ToSafeSummary()}], " +
                $"programmableObjectTypes=[{surface.CatalogSurface.ToSafeProgrammableObjectTypeSummary()}], " +
                $"schemas={surface.UnexpectedSchemaCount}, principals={surface.UnexpectedPrincipalCount}, " +
                $"roleMemberships={surface.RoleMembershipCount}, directPermissions={surface.UnexpectedDirectPermissionCount}, " +
                $"directPermissionTelemetry=[{surface.DirectPermissions.ToSafeSummary()}], " +
                $"options={surface.UnsafeDatabaseOptionCount}, ownerMismatch={surface.DatabaseOwnerMismatchCount}.");
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

public sealed record DatabaseSurfaceCategoryCount(string Category, int Count);

/// <summary>
/// Fixed, identifier-free telemetry for the complete unexpected catalog boundary.
/// Category labels are source-defined and counts are the only database values retained.
/// </summary>
public sealed class UnexpectedDatabaseSurfaceTelemetry
{
    private static readonly string[] FixedCategoryNames =
    [
        "programmableObjects",
        "triggers",
        "synonyms",
        "sequences",
        "externalTables",
        "externalDataSources",
        "externalFileFormats",
        "databaseScopedCredentials",
        "columnMasterKeys",
        "columnEncryptionKeys",
        "userAssemblies",
        "userDefinedOrTableTypes",
        "partitionFunctions",
        "partitionSchemes",
        "fullTextCatalogs",
        "fullTextIndexes",
        "userXmlSchemaCollections",
        "databaseAuditSpecifications",
        "securityPolicies",
        "databaseFirewallRules",
        "changeTrackingTables",
        "temporalPeriods",
        "sensitivityClassifications",
        "extendedProperties"
    ];

    private static readonly string[] FixedProgrammableObjectTypeNames =
    [
        "views",
        "sqlStoredProcedures",
        "clrStoredProcedures",
        "sqlScalarFunctions",
        "sqlInlineTableValuedFunctions",
        "sqlTableValuedFunctions",
        "clrScalarFunctions",
        "clrTableValuedFunctions",
        "aggregateFunctions"
    ];

    private static readonly string[] FixedSqlFieldNames =
    [
        .. FixedCategoryNames,
        .. FixedProgrammableObjectTypeNames
    ];

    private UnexpectedDatabaseSurfaceTelemetry(
        IReadOnlyList<DatabaseSurfaceCategoryCount> categories,
        IReadOnlyList<DatabaseSurfaceCategoryCount> programmableObjectTypes,
        int totalCount)
    {
        Categories = categories;
        ProgrammableObjectTypes = programmableObjectTypes;
        TotalCount = totalCount;
    }

    public static int ExpectedCategoryCount => FixedCategoryNames.Length;

    public static int ExpectedProgrammableObjectTypeCount => FixedProgrammableObjectTypeNames.Length;

    public static IReadOnlyList<string> CategoryNames => Array.AsReadOnly(FixedCategoryNames);

    public static IReadOnlyList<string> ProgrammableObjectTypeNames =>
        Array.AsReadOnly(FixedProgrammableObjectTypeNames);

    public static IReadOnlyList<string> SqlFieldNames => Array.AsReadOnly(FixedSqlFieldNames);

    public IReadOnlyList<DatabaseSurfaceCategoryCount> Categories { get; }

    public IReadOnlyList<DatabaseSurfaceCategoryCount> ProgrammableObjectTypes { get; }

    public int TotalCount { get; }

    public static UnexpectedDatabaseSurfaceTelemetry FromOrderedCounts(
        IReadOnlyList<int> categoryCounts,
        IReadOnlyList<int> programmableObjectTypeCounts)
    {
        ArgumentNullException.ThrowIfNull(categoryCounts);
        ArgumentNullException.ThrowIfNull(programmableObjectTypeCounts);
        if (categoryCounts.Count != FixedCategoryNames.Length)
        {
            throw new InvalidOperationException(
                $"Azure SQL returned {categoryCounts.Count} catalog counters; exactly {FixedCategoryNames.Length} are required.");
        }
        if (programmableObjectTypeCounts.Count != FixedProgrammableObjectTypeNames.Length)
        {
            throw new InvalidOperationException(
                $"Azure SQL returned {programmableObjectTypeCounts.Count} programmable-object type counters; exactly {FixedProgrammableObjectTypeNames.Length} are required.");
        }
        if (categoryCounts.Any(count => count < 0) ||
            programmableObjectTypeCounts.Any(count => count < 0))
        {
            throw new InvalidOperationException("Azure SQL returned a negative database-surface counter.");
        }

        var categories = FixedCategoryNames
            .Select((name, index) => new DatabaseSurfaceCategoryCount(name, categoryCounts[index]))
            .ToArray();
        var programmableObjectTypes = FixedProgrammableObjectTypeNames
            .Select((name, index) => new DatabaseSurfaceCategoryCount(name, programmableObjectTypeCounts[index]))
            .ToArray();

        var programmableObjectCount = SumChecked(programmableObjectTypeCounts);
        if (programmableObjectCount != categories[0].Count)
        {
            throw new InvalidOperationException(
                "Azure SQL returned inconsistent aggregate and typed programmable-object counters.");
        }
        return new UnexpectedDatabaseSurfaceTelemetry(
            Array.AsReadOnly(categories),
            Array.AsReadOnly(programmableObjectTypes),
            SumChecked(categoryCounts));
    }

    public string ToSafeSummary() => FormatSafeCounts(Categories);

    public string ToSafeProgrammableObjectTypeSummary() => FormatSafeCounts(ProgrammableObjectTypes);

    private static int SumChecked(IReadOnlyList<int> counts)
    {
        var total = 0;
        foreach (var count in counts)
            total = checked(total + count);
        return total;
    }

    private static string FormatSafeCounts(IEnumerable<DatabaseSurfaceCategoryCount> counts) =>
        string.Join(',', counts.Select(item => $"{item.Category}={item.Count}"));
}

/// <summary>
/// Fixed, identifier-free telemetry for the Azure SQL permission baseline.
/// </summary>
public sealed class DatabaseDirectPermissionTelemetry
{
    public const int ExpectedPositiveIdPublicSelectMsShippedObjectTargetCount = 2;

    private DatabaseDirectPermissionTelemetry(
        int rawNonWhitelistedCount,
        int positiveIdPublicSelectTargetCount,
        int positiveIdPublicSelectMsShippedObjectTargetCount,
        int positiveIdPublicSelectNonMsShippedProgrammableObjectCorrelationCount,
        int positiveIdPublicSelectMsShippedSystemCatalogTargetCount,
        int unexpectedCount)
    {
        RawNonWhitelistedCount = rawNonWhitelistedCount;
        PositiveIdPublicSelectTargetCount = positiveIdPublicSelectTargetCount;
        PositiveIdPublicSelectMsShippedObjectTargetCount = positiveIdPublicSelectMsShippedObjectTargetCount;
        PositiveIdPublicSelectNonMsShippedProgrammableObjectCorrelationCount =
            positiveIdPublicSelectNonMsShippedProgrammableObjectCorrelationCount;
        PositiveIdPublicSelectMsShippedSystemCatalogTargetCount =
            positiveIdPublicSelectMsShippedSystemCatalogTargetCount;
        UnexpectedCount = unexpectedCount;
    }

    public int RawNonWhitelistedCount { get; }

    public int PositiveIdPublicSelectTargetCount { get; }

    public int PositiveIdPublicSelectMsShippedObjectTargetCount { get; }

    public int PositiveIdPublicSelectNonMsShippedProgrammableObjectCorrelationCount { get; }

    public int PositiveIdPublicSelectMsShippedSystemCatalogTargetCount { get; }

    public int UnexpectedCount { get; }

    public static DatabaseDirectPermissionTelemetry FromCounts(
        int rawNonWhitelistedCount,
        int positiveIdPublicSelectTargetCount,
        int positiveIdPublicSelectMsShippedObjectTargetCount,
        int positiveIdPublicSelectNonMsShippedProgrammableObjectCorrelationCount,
        int positiveIdPublicSelectMsShippedSystemCatalogTargetCount)
    {
        if (rawNonWhitelistedCount < 0 ||
            positiveIdPublicSelectTargetCount < 0 ||
            positiveIdPublicSelectMsShippedObjectTargetCount < 0 ||
            positiveIdPublicSelectNonMsShippedProgrammableObjectCorrelationCount < 0 ||
            positiveIdPublicSelectMsShippedSystemCatalogTargetCount < 0)
        {
            throw new InvalidOperationException("Azure SQL returned a negative database-permission counter.");
        }
        if (positiveIdPublicSelectMsShippedObjectTargetCount > positiveIdPublicSelectTargetCount)
        {
            throw new InvalidOperationException(
                "Azure SQL returned inconsistent positive-ID public SELECT target or correlation counts.");
        }
        var nonMsShippedPositiveIdPublicSelectTargetCount = checked(
            positiveIdPublicSelectTargetCount - positiveIdPublicSelectMsShippedObjectTargetCount);
        if (nonMsShippedPositiveIdPublicSelectTargetCount > rawNonWhitelistedCount ||
            positiveIdPublicSelectNonMsShippedProgrammableObjectCorrelationCount > positiveIdPublicSelectTargetCount ||
            positiveIdPublicSelectNonMsShippedProgrammableObjectCorrelationCount >
                nonMsShippedPositiveIdPublicSelectTargetCount ||
            positiveIdPublicSelectNonMsShippedProgrammableObjectCorrelationCount > rawNonWhitelistedCount ||
            positiveIdPublicSelectMsShippedSystemCatalogTargetCount > positiveIdPublicSelectTargetCount ||
            positiveIdPublicSelectMsShippedSystemCatalogTargetCount > positiveIdPublicSelectMsShippedObjectTargetCount)
        {
            throw new InvalidOperationException(
                "Azure SQL returned inconsistent positive-ID public SELECT target or correlation counts.");
        }

        var baselineMismatch = positiveIdPublicSelectMsShippedObjectTargetCount ==
            ExpectedPositiveIdPublicSelectMsShippedObjectTargetCount
            ? 0
            : 1;
        return new DatabaseDirectPermissionTelemetry(
            rawNonWhitelistedCount,
            positiveIdPublicSelectTargetCount,
            positiveIdPublicSelectMsShippedObjectTargetCount,
            positiveIdPublicSelectNonMsShippedProgrammableObjectCorrelationCount,
            positiveIdPublicSelectMsShippedSystemCatalogTargetCount,
            checked(rawNonWhitelistedCount + baselineMismatch));
    }

    public string ToSafeSummary() =>
        $"rawNonWhitelisted={RawNonWhitelistedCount}," +
        $"positiveIdPublicSelectTargets={PositiveIdPublicSelectTargetCount}," +
        $"positiveIdPublicSelectMsShippedObjectTargets={PositiveIdPublicSelectMsShippedObjectTargetCount}," +
        $"positiveIdPublicSelectNonMsShippedProgrammableObjectCorrelations=" +
        $"{PositiveIdPublicSelectNonMsShippedProgrammableObjectCorrelationCount}," +
        $"positiveIdPublicSelectMsShippedSystemCatalogTargets=" +
        $"{PositiveIdPublicSelectMsShippedSystemCatalogTargetCount}";
}

public sealed record PristineDatabaseSurfaceSnapshot(
    int UserTableCount,
    UnexpectedDatabaseSurfaceTelemetry CatalogSurface,
    int UnexpectedSchemaCount,
    int UnexpectedPrincipalCount,
    int RoleMembershipCount,
    DatabaseDirectPermissionTelemetry DirectPermissions,
    int UnsafeDatabaseOptionCount,
    int DatabaseOwnerMismatchCount)
{
    private static readonly string[] FixedSqlFieldNames =
    [
        .. UnexpectedDatabaseSurfaceTelemetry.SqlFieldNames,
        "userTables",
        "unexpectedSchemas",
        "unexpectedPrincipals",
        "unexpectedRoleMemberships",
        "rawNonWhitelistedDirectPermissions",
        "positiveIdPublicSelectTargets",
        "positiveIdPublicSelectMsShippedObjectTargets",
        "positiveIdPublicSelectNonMsShippedProgrammableObjectCorrelations",
        "positiveIdPublicSelectMsShippedSystemCatalogTargets",
        "unsafeDatabaseOptions",
        "databaseOwnerMismatches"
    ];

    public static IReadOnlyList<string> SqlFieldNames => Array.AsReadOnly(FixedSqlFieldNames);

    public int UnexpectedObjectCount => CatalogSurface.TotalCount;

    public int UnexpectedDirectPermissionCount => DirectPermissions.UnexpectedCount;
}

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
