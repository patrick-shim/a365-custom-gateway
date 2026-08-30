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
    public const int ExpectedPositiveIdPublicSelectTargetCount = 1;
    public const int ExpectedPositiveIdPublicSelectMsShippedObjectTargetCount = 1;
    public const int ExpectedPositiveIdPublicSelectMsShippedSystemCatalogTargetCount = 0;
    public const int ExpectedPositiveIdPublicSelectMsShippedDatabaseObjectOnlyTargetCount = 1;

    private static readonly string[] FixedLeadingFieldNames =
    [
        "rawNonWhitelistedDirectPermissions",
        "positiveIdPublicSelectTargets",
        "positiveIdPublicSelectMsShippedObjectTargets",
        "positiveIdPublicSelectNonMsShippedProgrammableObjectCorrelations",
        "positiveIdPublicSelectMsShippedSystemCatalogTargets",
        "positiveIdPublicSelectMsShippedDatabaseObjectOnlyTargets",
        "positiveIdPublicSelectNonMsShippedOrUnresolvedTargets"
    ];

    private static readonly string[] FixedRawClassFieldNames =
    [
        "rawClassDatabasePermissions",
        "rawClassObjectOrColumnPermissions",
        "rawClassOtherPermissions"
    ];

    private static readonly string[] FixedRawStateFieldNames =
    [
        "rawStateGrantPermissions",
        "rawStateGrantWithGrantOptionPermissions",
        "rawStateDenyPermissions",
        "rawStateRevokePermissions",
        "rawStateOtherPermissions"
    ];

    private static readonly string[] FixedRawGranteeFieldNames =
    [
        "rawGranteePublicPermissions",
        "rawGranteeGuestPermissions",
        "rawGranteeDboPermissions",
        "rawGranteeFixedRolePermissions",
        "rawGranteeOtherPermissions"
    ];

    private static readonly string[] FixedRawPermissionNameFieldNames =
    [
        "rawPermissionNameConnect",
        "rawPermissionNameSelect",
        "rawPermissionNameViewDefinition",
        "rawPermissionNameViewAnyColumnMasterKeyDefinition",
        "rawPermissionNameViewAnyColumnEncryptionKeyDefinition",
        "rawPermissionNameOther"
    ];

    private static readonly string[] FixedRawAddressFieldNames =
    [
        "rawAddressDatabase",
        "rawAddressNegativeObject",
        "rawAddressZeroObject",
        "rawAddressPositiveObject",
        "rawAddressColumn",
        "rawAddressOther"
    ];

    private static readonly string[] FixedRawGrantorFieldNames =
    [
        "rawGrantorDbo",
        "rawGrantorOther"
    ];

    private static readonly string[] FixedPositiveTargetTypeFieldNames =
    [
        "positiveIdPublicSelectTypeAggregateFunctions",
        "positiveIdPublicSelectTypeCheckConstraints",
        "positiveIdPublicSelectTypeDefaultConstraints",
        "positiveIdPublicSelectTypeEdgeConstraints",
        "positiveIdPublicSelectTypeExternalTables",
        "positiveIdPublicSelectTypeForeignKeys",
        "positiveIdPublicSelectTypeSqlScalarFunctions",
        "positiveIdPublicSelectTypeClrScalarFunctions",
        "positiveIdPublicSelectTypeClrTableValuedFunctions",
        "positiveIdPublicSelectTypeSqlInlineTableValuedFunctions",
        "positiveIdPublicSelectTypeInternalTables",
        "positiveIdPublicSelectTypeSqlStoredProcedures",
        "positiveIdPublicSelectTypeClrStoredProcedures",
        "positiveIdPublicSelectTypePlanGuides",
        "positiveIdPublicSelectTypePrimaryKeys",
        "positiveIdPublicSelectTypeRules",
        "positiveIdPublicSelectTypeReplicationFilterProcedures",
        "positiveIdPublicSelectTypeSystemTables",
        "positiveIdPublicSelectTypeSynonyms",
        "positiveIdPublicSelectTypeSequences",
        "positiveIdPublicSelectTypeServiceQueues",
        "positiveIdPublicSelectTypeStatisticsTrees",
        "positiveIdPublicSelectTypeClrDmlTriggers",
        "positiveIdPublicSelectTypeSqlTableValuedFunctions",
        "positiveIdPublicSelectTypeSqlDmlTriggers",
        "positiveIdPublicSelectTypeTableTypes",
        "positiveIdPublicSelectTypeUserTables",
        "positiveIdPublicSelectTypeUniqueConstraints",
        "positiveIdPublicSelectTypeViews",
        "positiveIdPublicSelectTypeExtendedStoredProcedures",
        "positiveIdPublicSelectTypeOtherOrUnresolved"
    ];

    private static readonly string[] FixedPositiveTargetSchemaFieldNames =
    [
        "positiveIdPublicSelectSchemaSys",
        "positiveIdPublicSelectSchemaDbo",
        "positiveIdPublicSelectSchemaOtherOrUnresolved"
    ];

    private static readonly string[] FixedPositiveTargetParentFieldNames =
    [
        "positiveIdPublicSelectParentless",
        "positiveIdPublicSelectParented",
        "positiveIdPublicSelectParentUnresolved"
    ];

    private static readonly string[] FixedPositiveTargetSpecializedCatalogFieldNames =
    [
        "positiveIdPublicSelectInViews",
        "positiveIdPublicSelectInProcedures",
        "positiveIdPublicSelectInSqlModules",
        "positiveIdPublicSelectInTables",
        "positiveIdPublicSelectInInternalTables",
        "positiveIdPublicSelectInSequences",
        "positiveIdPublicSelectInSynonyms",
        "positiveIdPublicSelectInTriggers"
    ];

    private static readonly string[] FixedPositiveTargetSpecializedPartitionFieldNames =
    [
        "positiveIdPublicSelectWithSpecializedCatalogMembership",
        "positiveIdPublicSelectWithoutSpecializedCatalogMembership"
    ];

    private static readonly string[] FixedSqlFieldNames =
    [
        .. FixedLeadingFieldNames,
        .. FixedRawClassFieldNames,
        .. FixedRawStateFieldNames,
        .. FixedRawGranteeFieldNames,
        .. FixedRawPermissionNameFieldNames,
        .. FixedRawAddressFieldNames,
        .. FixedRawGrantorFieldNames,
        .. FixedPositiveTargetTypeFieldNames,
        .. FixedPositiveTargetSchemaFieldNames,
        .. FixedPositiveTargetParentFieldNames,
        .. FixedPositiveTargetSpecializedCatalogFieldNames,
        .. FixedPositiveTargetSpecializedPartitionFieldNames
    ];

    private DatabaseDirectPermissionTelemetry(
        IReadOnlyList<DatabaseSurfaceCategoryCount> counts,
        int unexpectedCount)
    {
        Counts = counts;
        UnexpectedCount = unexpectedCount;
    }

    public static int ExpectedFieldCount => FixedSqlFieldNames.Length;

    public static IReadOnlyList<string> SqlFieldNames => Array.AsReadOnly(FixedSqlFieldNames);

    public IReadOnlyList<DatabaseSurfaceCategoryCount> Counts { get; }

    public int RawNonWhitelistedCount => Counts[0].Count;

    public int PositiveIdPublicSelectTargetCount => Counts[1].Count;

    public int PositiveIdPublicSelectMsShippedObjectTargetCount => Counts[2].Count;

    public int PositiveIdPublicSelectNonMsShippedProgrammableObjectCorrelationCount => Counts[3].Count;

    public int PositiveIdPublicSelectMsShippedSystemCatalogTargetCount => Counts[4].Count;

    public int PositiveIdPublicSelectMsShippedDatabaseObjectOnlyTargetCount => Counts[5].Count;

    public int PositiveIdPublicSelectNonMsShippedOrUnresolvedTargetCount => Counts[6].Count;

    public int UnexpectedCount { get; }

    public static DatabaseDirectPermissionTelemetry FromOrderedCounts(IReadOnlyList<int> orderedCounts)
    {
        ArgumentNullException.ThrowIfNull(orderedCounts);
        if (orderedCounts.Count != FixedSqlFieldNames.Length)
        {
            throw new InvalidOperationException(
                $"Azure SQL returned {orderedCounts.Count} database-permission counters; exactly {FixedSqlFieldNames.Length} are required.");
        }
        if (orderedCounts.Any(count => count < 0))
        {
            throw new InvalidOperationException("Azure SQL returned a negative database-permission counter.");
        }

        var counts = orderedCounts.ToArray();
        var rawNonWhitelistedCount = counts[0];
        var positiveIdPublicSelectTargetCount = counts[1];
        var positiveIdPublicSelectMsShippedObjectTargetCount = counts[2];
        var positiveIdPublicSelectNonMsShippedProgrammableObjectCorrelationCount = counts[3];
        var positiveIdPublicSelectMsShippedSystemCatalogTargetCount = counts[4];
        var positiveIdPublicSelectMsShippedDatabaseObjectOnlyTargetCount = counts[5];
        var positiveIdPublicSelectNonMsShippedOrUnresolvedTargetCount = counts[6];

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
            positiveIdPublicSelectMsShippedSystemCatalogTargetCount > positiveIdPublicSelectMsShippedObjectTargetCount ||
            positiveIdPublicSelectMsShippedDatabaseObjectOnlyTargetCount > positiveIdPublicSelectTargetCount ||
            positiveIdPublicSelectNonMsShippedOrUnresolvedTargetCount > positiveIdPublicSelectTargetCount)
        {
            throw new InvalidOperationException(
                "Azure SQL returned inconsistent positive-ID public SELECT target or correlation counts.");
        }

        var cursor = FixedLeadingFieldNames.Length;
        ValidateExactPartition(counts, ref cursor, FixedRawClassFieldNames.Length, rawNonWhitelistedCount);
        ValidateExactPartition(counts, ref cursor, FixedRawStateFieldNames.Length, rawNonWhitelistedCount);
        ValidateExactPartition(counts, ref cursor, FixedRawGranteeFieldNames.Length, rawNonWhitelistedCount);
        ValidateExactPartition(counts, ref cursor, FixedRawPermissionNameFieldNames.Length, rawNonWhitelistedCount);
        ValidateExactPartition(counts, ref cursor, FixedRawAddressFieldNames.Length, rawNonWhitelistedCount);
        ValidateExactPartition(counts, ref cursor, FixedRawGrantorFieldNames.Length, rawNonWhitelistedCount);
        ValidateExactPartition(counts, ref cursor, FixedPositiveTargetTypeFieldNames.Length, positiveIdPublicSelectTargetCount);
        ValidateExactPartition(counts, ref cursor, FixedPositiveTargetSchemaFieldNames.Length, positiveIdPublicSelectTargetCount);
        ValidateExactPartition(counts, ref cursor, FixedPositiveTargetParentFieldNames.Length, positiveIdPublicSelectTargetCount);

        var specializedMembershipStart = cursor;
        cursor = checked(cursor + FixedPositiveTargetSpecializedCatalogFieldNames.Length);
        var specializedMembershipCount = counts[cursor];
        var noSpecializedMembershipCount = counts[checked(cursor + 1)];
        if (checked(specializedMembershipCount + noSpecializedMembershipCount) !=
            positiveIdPublicSelectTargetCount)
        {
            throw new InvalidOperationException(
                "Azure SQL returned an inconsistent database-permission telemetry partition.");
        }
        var specializedCorrelationTotal = 0;
        for (var index = specializedMembershipStart; index < cursor; index++)
        {
            if (counts[index] > specializedMembershipCount)
            {
                throw new InvalidOperationException(
                    "Azure SQL returned an inconsistent database-permission telemetry correlation.");
            }
            specializedCorrelationTotal = checked(specializedCorrelationTotal + counts[index]);
        }
        if (specializedMembershipCount > specializedCorrelationTotal)
        {
            throw new InvalidOperationException(
                "Azure SQL returned an inconsistent database-permission telemetry correlation.");
        }
        cursor = checked(cursor + FixedPositiveTargetSpecializedPartitionFieldNames.Length);
        if (cursor != counts.Length)
        {
            throw new InvalidOperationException(
                "The fixed database-permission telemetry field contract is inconsistent.");
        }

        if (checked(
                positiveIdPublicSelectMsShippedSystemCatalogTargetCount +
                positiveIdPublicSelectMsShippedDatabaseObjectOnlyTargetCount) !=
            positiveIdPublicSelectMsShippedObjectTargetCount ||
            checked(
                positiveIdPublicSelectMsShippedSystemCatalogTargetCount +
                positiveIdPublicSelectMsShippedDatabaseObjectOnlyTargetCount +
                positiveIdPublicSelectNonMsShippedOrUnresolvedTargetCount) !=
            positiveIdPublicSelectTargetCount ||
            positiveIdPublicSelectNonMsShippedOrUnresolvedTargetCount !=
            nonMsShippedPositiveIdPublicSelectTargetCount)
        {
            throw new InvalidOperationException(
                "Azure SQL returned an inconsistent positive-ID public SELECT target partition.");
        }

        var baselineMismatch =
            positiveIdPublicSelectTargetCount == ExpectedPositiveIdPublicSelectTargetCount &&
            positiveIdPublicSelectMsShippedObjectTargetCount ==
                ExpectedPositiveIdPublicSelectMsShippedObjectTargetCount &&
            positiveIdPublicSelectMsShippedSystemCatalogTargetCount ==
                ExpectedPositiveIdPublicSelectMsShippedSystemCatalogTargetCount &&
            positiveIdPublicSelectMsShippedDatabaseObjectOnlyTargetCount ==
                ExpectedPositiveIdPublicSelectMsShippedDatabaseObjectOnlyTargetCount &&
            positiveIdPublicSelectNonMsShippedOrUnresolvedTargetCount == 0
            ? 0
            : 1;

        var fixedCounts = FixedSqlFieldNames
            .Select((name, index) => new DatabaseSurfaceCategoryCount(name, counts[index]))
            .ToArray();
        return new DatabaseDirectPermissionTelemetry(
            Array.AsReadOnly(fixedCounts),
            checked(rawNonWhitelistedCount + baselineMismatch));
    }

    public string ToSafeSummary() =>
        string.Join(',', Counts.Select(item => $"{item.Category}={item.Count}"));

    private static void ValidateExactPartition(
        IReadOnlyList<int> counts,
        ref int cursor,
        int partitionLength,
        int expectedTotal)
    {
        var observedTotal = 0;
        var end = checked(cursor + partitionLength);
        for (var index = cursor; index < end; index++)
            observedTotal = checked(observedTotal + counts[index]);
        if (observedTotal != expectedTotal)
        {
            throw new InvalidOperationException(
                "Azure SQL returned an inconsistent database-permission telemetry partition.");
        }
        cursor = end;
    }
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
        .. DatabaseDirectPermissionTelemetry.SqlFieldNames,
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
