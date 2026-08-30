using FluentAssertions;
using Gateway.DatabaseMigrator;

namespace Gateway.UnitTests.Infrastructure;

public sealed class DatabaseMigratorRecoveryContractTests
{
    private const string ExpectedMarker = "{\"schemaVersion\":1,\"deploymentOwnershipId\":\"11111111-1111-4111-8111-111111111111\"}";

    [Fact]
    public void Initialization_ClassifiesFreshOnlyWhenDatabaseHasNoTablesAndNoMarker()
    {
        DatabaseBootstrapRecoveryContract.Classify(0, null, ExpectedMarker, exactCurrentSchema: false)
            .Should().Be(DatabaseInitializationRecoveryMode.Fresh);
    }

    [Fact]
    public void Initialization_ResumesMatchingMarkerBeforeFirstTable()
    {
        DatabaseBootstrapRecoveryContract.Classify(0, ExpectedMarker, ExpectedMarker, exactCurrentSchema: false)
            .Should().Be(DatabaseInitializationRecoveryMode.ResumeBeforeSchemaMutation);
    }

    [Fact]
    public void Initialization_ResumesOnlyACompleteExactSchemaAfterTablesExist()
    {
        DatabaseBootstrapRecoveryContract.Classify(15, ExpectedMarker, ExpectedMarker, exactCurrentSchema: true)
            .Should().Be(DatabaseInitializationRecoveryMode.ResumeAfterSchemaCompleted);
    }

    [Fact]
    public void Initialization_RejectsNonemptyDatabaseWithoutDurableIntent()
    {
        var action = () => DatabaseBootstrapRecoveryContract.Classify(
            1,
            null,
            ExpectedMarker,
            exactCurrentSchema: false);

        action.Should().Throw<InvalidOperationException>()
            .WithMessage("*no durable bootstrap initialization marker*");
    }

    [Theory]
    [InlineData(0)]
    [InlineData(15)]
    public void Initialization_RejectsMarkerFromAnotherDeploymentOrSource(int tableCount)
    {
        var action = () => DatabaseBootstrapRecoveryContract.Classify(
            tableCount,
            "different-marker",
            ExpectedMarker,
            exactCurrentSchema: tableCount > 0);

        action.Should().Throw<InvalidOperationException>()
            .WithMessage("*does not match this exact deployment ownership, source, server, and database*");
    }

    [Fact]
    public void Initialization_RejectsMatchingMarkerWithPartialSchema()
    {
        var action = () => DatabaseBootstrapRecoveryContract.Classify(
            3,
            ExpectedMarker,
            ExpectedMarker,
            exactCurrentSchema: false);

        action.Should().Throw<InvalidOperationException>()
            .WithMessage("*partial initialization is never continued automatically*");
    }

    [Fact]
    public void Initialization_AcceptsOnlyAnEntirelyPristineDatabaseSurface()
    {
        var action = () => DatabaseBootstrapRecoveryContract.AssertPristine(CreatePristineSurface());

        action.Should().NotThrow();
    }

    public static IEnumerable<object[]> NonPristineDatabaseSurfaces()
    {
        var pristine = CreatePristineSurface();
        yield return [pristine with { UserTableCount = 1 }];
        yield return [pristine with { UnexpectedSchemaCount = 1 }];
        yield return [pristine with { UnexpectedPrincipalCount = 1 }];
        yield return [pristine with { RoleMembershipCount = 1 }];
        yield return [pristine with { DirectPermissions = DatabaseDirectPermissionTelemetry.FromCounts(1, 3, 2, 1, 2) }];
        yield return [pristine with { DirectPermissions = DatabaseDirectPermissionTelemetry.FromCounts(0, 1, 1, 0, 1) }];
        yield return [pristine with { DirectPermissions = DatabaseDirectPermissionTelemetry.FromCounts(0, 3, 3, 0, 3) }];
        yield return [pristine with { UnsafeDatabaseOptionCount = 1 }];
        yield return [pristine with { DatabaseOwnerMismatchCount = 1 }];
    }

    [Theory]
    [MemberData(nameof(NonPristineDatabaseSurfaces))]
    public void Initialization_RejectsEveryNonPristineDatabaseSurface(
        PristineDatabaseSurfaceSnapshot surface)
    {
        var action = () => DatabaseBootstrapRecoveryContract.AssertPristine(surface);

        action.Should().Throw<InvalidOperationException>()
            .WithMessage(
                "*requires a pristine database surface*" +
                "tables=*, objects=*, catalog=[*], programmableObjectTypes=[*], " +
                "schemas=*, principals=*, roleMemberships=*, directPermissions=*, " +
                "directPermissionTelemetry=[*], options=*, ownerMismatch=*.");
    }

    [Fact]
    public void Initialization_FailureReportsEverySafeCountInOrder()
    {
        var catalogCounts = CreateZeroCatalogCounts();
        catalogCounts[1] = 2;
        var surface = new PristineDatabaseSurfaceSnapshot(
            1,
            UnexpectedDatabaseSurfaceTelemetry.FromOrderedCounts(
                catalogCounts,
                CreateZeroProgrammableObjectTypeCounts()),
            3,
            4,
            5,
            DatabaseDirectPermissionTelemetry.FromCounts(6, 8, 2, 1, 2),
            7,
            8);

        var action = () => DatabaseBootstrapRecoveryContract.AssertPristine(surface);

        action.Should().Throw<InvalidOperationException>()
            .WithMessage(
                "Clean bootstrap requires a pristine database surface before its durable initialization marker is written; " +
                "safe counts were tables=1, objects=2, " +
                "catalog=[programmableObjects=0,triggers=2,synonyms=0,sequences=0,externalTables=0," +
                "externalDataSources=0,externalFileFormats=0,databaseScopedCredentials=0,columnMasterKeys=0," +
                "columnEncryptionKeys=0,userAssemblies=0,userDefinedOrTableTypes=0,partitionFunctions=0," +
                "partitionSchemes=0,fullTextCatalogs=0,fullTextIndexes=0,userXmlSchemaCollections=0," +
                "databaseAuditSpecifications=0,securityPolicies=0,databaseFirewallRules=0," +
                "changeTrackingTables=0,temporalPeriods=0,sensitivityClassifications=0,extendedProperties=0], " +
                "programmableObjectTypes=[views=0,sqlStoredProcedures=0,clrStoredProcedures=0," +
                "sqlScalarFunctions=0,sqlInlineTableValuedFunctions=0,sqlTableValuedFunctions=0," +
                "clrScalarFunctions=0,clrTableValuedFunctions=0,aggregateFunctions=0], " +
                "schemas=3, principals=4, roleMemberships=5, directPermissions=6, " +
                "directPermissionTelemetry=[rawNonWhitelisted=6,positiveIdPublicSelectTargets=8," +
                "positiveIdPublicSelectMsShippedObjectTargets=2," +
                "positiveIdPublicSelectNonMsShippedProgrammableObjectCorrelations=1," +
                "positiveIdPublicSelectMsShippedSystemCatalogTargets=2], options=7, ownerMismatch=8.");
    }

    public static IEnumerable<object[]> UnexpectedCatalogCategoryIndexes() =>
        Enumerable.Range(0, UnexpectedDatabaseSurfaceTelemetry.ExpectedCategoryCount)
            .Select(index => new object[] { index });

    [Theory]
    [MemberData(nameof(UnexpectedCatalogCategoryIndexes))]
    public void Initialization_RejectsEveryNonzeroCatalogCategoryAndReportsItsFixedLabel(int categoryIndex)
    {
        var categoryCounts = CreateZeroCatalogCounts();
        var objectTypeCounts = CreateZeroProgrammableObjectTypeCounts();
        categoryCounts[categoryIndex] = 1;
        if (categoryIndex == 0)
            objectTypeCounts[0] = 1;
        var catalog = UnexpectedDatabaseSurfaceTelemetry.FromOrderedCounts(
            categoryCounts,
            objectTypeCounts);
        var surface = CreatePristineSurface() with { CatalogSurface = catalog };

        var action = () => DatabaseBootstrapRecoveryContract.AssertPristine(surface);

        action.Should().Throw<InvalidOperationException>()
            .WithMessage($"*{UnexpectedDatabaseSurfaceTelemetry.CategoryNames[categoryIndex]}=1*");
    }

    [Fact]
    public void CatalogTelemetry_DerivesCheckedTotalFromTheFixedOrderedVector()
    {
        var categoryCounts = CreateZeroCatalogCounts();
        categoryCounts[1] = 2;
        categoryCounts[^1] = 3;

        var telemetry = UnexpectedDatabaseSurfaceTelemetry.FromOrderedCounts(
            categoryCounts,
            CreateZeroProgrammableObjectTypeCounts());

        telemetry.TotalCount.Should().Be(5);
        telemetry.Categories.Should().HaveCount(24);
        telemetry.Categories.Select(item => item.Category)
            .Should().Equal(UnexpectedDatabaseSurfaceTelemetry.CategoryNames);
        UnexpectedDatabaseSurfaceTelemetry.SqlFieldNames
            .Should().Equal(
                UnexpectedDatabaseSurfaceTelemetry.CategoryNames
                    .Concat(UnexpectedDatabaseSurfaceTelemetry.ProgrammableObjectTypeNames));
    }

    [Fact]
    public void SqlFieldContracts_AreFrozenInExactOrder()
    {
        string[] catalogFields =
        [
            "programmableObjects", "triggers", "synonyms", "sequences", "externalTables",
            "externalDataSources", "externalFileFormats", "databaseScopedCredentials", "columnMasterKeys",
            "columnEncryptionKeys", "userAssemblies", "userDefinedOrTableTypes", "partitionFunctions",
            "partitionSchemes", "fullTextCatalogs", "fullTextIndexes", "userXmlSchemaCollections",
            "databaseAuditSpecifications", "securityPolicies", "databaseFirewallRules", "changeTrackingTables",
            "temporalPeriods", "sensitivityClassifications", "extendedProperties", "views", "sqlStoredProcedures",
            "clrStoredProcedures", "sqlScalarFunctions", "sqlInlineTableValuedFunctions",
            "sqlTableValuedFunctions", "clrScalarFunctions", "clrTableValuedFunctions", "aggregateFunctions"
        ];
        string[] pristineOnlyFields =
        [
            "userTables", "unexpectedSchemas", "unexpectedPrincipals", "unexpectedRoleMemberships",
            "rawNonWhitelistedDirectPermissions", "positiveIdPublicSelectTargets",
            "positiveIdPublicSelectMsShippedObjectTargets",
            "positiveIdPublicSelectNonMsShippedProgrammableObjectCorrelations",
            "positiveIdPublicSelectMsShippedSystemCatalogTargets", "unsafeDatabaseOptions",
            "databaseOwnerMismatches"
        ];

        UnexpectedDatabaseSurfaceTelemetry.SqlFieldNames.Should().Equal(catalogFields);
        PristineDatabaseSurfaceSnapshot.SqlFieldNames.Should().Equal(catalogFields.Concat(pristineOnlyFields));
    }

    [Fact]
    public void CatalogTelemetry_RejectsWrongCardinalityNegativeCountsAndObjectTypeMismatch()
    {
        var objectTypes = CreateZeroProgrammableObjectTypeCounts();
        var categories = CreateZeroCatalogCounts();
        var wrongCategoryCardinality = () => UnexpectedDatabaseSurfaceTelemetry.FromOrderedCounts(
            categories[..^1],
            objectTypes);
        var wrongTypeCardinality = () => UnexpectedDatabaseSurfaceTelemetry.FromOrderedCounts(
            categories,
            objectTypes[..^1]);
        var negativeCategories = CreateZeroCatalogCounts();
        negativeCategories[1] = -1;
        var negative = () => UnexpectedDatabaseSurfaceTelemetry.FromOrderedCounts(
            negativeCategories,
            objectTypes);
        var negativeObjectTypes = CreateZeroProgrammableObjectTypeCounts();
        negativeObjectTypes[1] = -1;
        var negativeType = () => UnexpectedDatabaseSurfaceTelemetry.FromOrderedCounts(
            categories,
            negativeObjectTypes);
        var aggregateCategories = CreateZeroCatalogCounts();
        aggregateCategories[0] = 1;
        var mismatchedObjectTypes = () => UnexpectedDatabaseSurfaceTelemetry.FromOrderedCounts(
            aggregateCategories,
            objectTypes);

        wrongCategoryCardinality.Should().Throw<InvalidOperationException>();
        wrongTypeCardinality.Should().Throw<InvalidOperationException>();
        negative.Should().Throw<InvalidOperationException>();
        negativeType.Should().Throw<InvalidOperationException>();
        mismatchedObjectTypes.Should().Throw<InvalidOperationException>();
    }

    public static IEnumerable<object[]> ProgrammableObjectTypeIndexes() =>
        Enumerable.Range(0, UnexpectedDatabaseSurfaceTelemetry.ExpectedProgrammableObjectTypeCount)
            .Select(index => new object[] { index });

    [Theory]
    [MemberData(nameof(ProgrammableObjectTypeIndexes))]
    public void Initialization_RejectsEveryNonzeroProgrammableObjectType(int typeIndex)
    {
        var categoryCounts = CreateZeroCatalogCounts();
        var objectTypeCounts = CreateZeroProgrammableObjectTypeCounts();
        categoryCounts[0] = 1;
        objectTypeCounts[typeIndex] = 1;
        var catalog = UnexpectedDatabaseSurfaceTelemetry.FromOrderedCounts(
            categoryCounts,
            objectTypeCounts);

        var action = () => DatabaseBootstrapRecoveryContract.AssertPristine(
            CreatePristineSurface() with { CatalogSurface = catalog });

        action.Should().Throw<InvalidOperationException>()
            .WithMessage($"*{UnexpectedDatabaseSurfaceTelemetry.ProgrammableObjectTypeNames[typeIndex]}=1*");
    }

    [Fact]
    public void CatalogTelemetry_RejectsCategoryAndTypeTotalOverflow()
    {
        var overflowingCategories = CreateZeroCatalogCounts();
        overflowingCategories[1] = int.MaxValue;
        overflowingCategories[2] = 1;
        var categoryOverflow = () => UnexpectedDatabaseSurfaceTelemetry.FromOrderedCounts(
            overflowingCategories,
            CreateZeroProgrammableObjectTypeCounts());

        var overflowingTypes = CreateZeroProgrammableObjectTypeCounts();
        overflowingTypes[0] = int.MaxValue;
        overflowingTypes[1] = 1;
        var typeOverflow = () => UnexpectedDatabaseSurfaceTelemetry.FromOrderedCounts(
            CreateZeroCatalogCounts(),
            overflowingTypes);

        categoryOverflow.Should().Throw<OverflowException>();
        typeOverflow.Should().Throw<OverflowException>();
    }

    [Theory]
    [InlineData(0, 2, 2, 0, 2, 0)]
    [InlineData(1, 3, 2, 1, 2, 1)]
    [InlineData(0, 1, 1, 0, 1, 1)]
    [InlineData(0, 3, 3, 0, 3, 1)]
    public void DirectPermissionTelemetry_PreservesExactTwoSystemSelectBaseline(
        int rawNonWhitelisted,
        int positiveIdTargets,
        int positiveIdMsShippedObjectTargets,
        int positiveIdNonMsShippedProgrammableObjectCorrelations,
        int positiveIdMsShippedSystemCatalogTargets,
        int expectedUnexpected)
    {
        var telemetry = DatabaseDirectPermissionTelemetry.FromCounts(
            rawNonWhitelisted,
            positiveIdTargets,
            positiveIdMsShippedObjectTargets,
            positiveIdNonMsShippedProgrammableObjectCorrelations,
            positiveIdMsShippedSystemCatalogTargets);

        telemetry.UnexpectedCount.Should().Be(expectedUnexpected);
        telemetry.ToSafeSummary().Should().Be(
            $"rawNonWhitelisted={rawNonWhitelisted}," +
            $"positiveIdPublicSelectTargets={positiveIdTargets}," +
            $"positiveIdPublicSelectMsShippedObjectTargets={positiveIdMsShippedObjectTargets}," +
            "positiveIdPublicSelectNonMsShippedProgrammableObjectCorrelations=" +
            $"{positiveIdNonMsShippedProgrammableObjectCorrelations}," +
            $"positiveIdPublicSelectMsShippedSystemCatalogTargets={positiveIdMsShippedSystemCatalogTargets}");
    }

    [Fact]
    public void DirectPermissionTelemetry_RejectsNegativeOrInconsistentCounts()
    {
        var negative = () => DatabaseDirectPermissionTelemetry.FromCounts(0, 2, 2, 0, -1);
        var negativeProgrammableCorrelation = () => DatabaseDirectPermissionTelemetry.FromCounts(0, 2, 2, -1, 2);
        var shippedExceedsTotal = () => DatabaseDirectPermissionTelemetry.FromCounts(0, 1, 2, 0, 1);
        var programmableExceedsTotal = () => DatabaseDirectPermissionTelemetry.FromCounts(2, 1, 0, 2, 0);
        var programmableExceedsRaw = () => DatabaseDirectPermissionTelemetry.FromCounts(0, 3, 2, 1, 2);
        var unaccountedNonMsShippedTarget = () => DatabaseDirectPermissionTelemetry.FromCounts(0, 3, 2, 0, 2);
        var programmableExceedsNonMsShippedTargets = () =>
            DatabaseDirectPermissionTelemetry.FromCounts(2, 3, 2, 2, 2);
        var systemCatalogExceedsTotal = () => DatabaseDirectPermissionTelemetry.FromCounts(0, 1, 1, 0, 2);
        var systemCatalogExceedsShipped = () => DatabaseDirectPermissionTelemetry.FromCounts(0, 2, 1, 0, 2);

        negative.Should().Throw<InvalidOperationException>();
        negativeProgrammableCorrelation.Should().Throw<InvalidOperationException>();
        shippedExceedsTotal.Should().Throw<InvalidOperationException>();
        programmableExceedsTotal.Should().Throw<InvalidOperationException>();
        programmableExceedsRaw.Should().Throw<InvalidOperationException>();
        unaccountedNonMsShippedTarget.Should().Throw<InvalidOperationException>();
        programmableExceedsNonMsShippedTargets.Should().Throw<InvalidOperationException>();
        systemCatalogExceedsTotal.Should().Throw<InvalidOperationException>();
        systemCatalogExceedsShipped.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void DirectPermissionTelemetry_RejectsCheckedUnexpectedCountOverflow()
    {
        var action = () => DatabaseDirectPermissionTelemetry.FromCounts(
            int.MaxValue,
            0,
            0,
            0,
            0);

        action.Should().Throw<OverflowException>();
    }

    public static IEnumerable<object[]> SchemaDriftCases()
    {
        var exact = CreateExactSchema();
        yield return [exact with { Tables = ["dbo.Other|temporal:0|memory:0|durability:SCHEMA_AND_DATA|lobspace:-|filestreamspace:-|external:0|filetable:0|node:0|edge:0|ledger:0|lock:TABLE|lockbulk:0|largeout:0|replicated:0|merge:0|syncrepl:0|cdc:0|archive:0|ansinulls:1|replfilter:0"] }];
        yield return [exact with { Columns = ["dbo.Agents|Id|uniqueidentifier|0|default:-|computed:-|stored:0|identity:0:-:-:nfr:0|rowversion:1|generated:0|sparse:0|columnset:0|filestream:0|collation:-|encrypted:0:-:-|masked:0:-|hidden:0|xml:0:0|rule:0"] }];
        yield return [exact with { PrimaryKeys = ["dbo.Agents|PK_Drift|Id:A|type:CLUSTERED|space:PRIMARY|disabled:0|hypothetical:0|fill:0|padded:0|ignoredup:0|rowlocks:1|pagelocks:1|seq:0|statsnorecompute:0"] }];
        yield return [exact with { UniqueConstraints = ["dbo.Agents|AK_Drift|ExternalId:A|type:NONCLUSTERED|space:PRIMARY|disabled:0|hypothetical:0|fill:0|padded:0|ignoredup:0|rowlocks:1|pagelocks:1|seq:0|statsnorecompute:0"] }];
        yield return [exact with { ForeignKeys = ["dbo.Agents|FK_Drift|OwnerId|dbo.Owners|Id|delete:NO_ACTION|update:CASCADE|disabled:0|untrusted:0"] }];
        yield return [exact with { CheckConstraints = ["dbo.Agents|CK_Drift|id<>0|disabled:0|untrusted:0"] }];
        yield return [exact with { Indexes = ["dbo.Agents|IX_Drift|unique:1|filter:-|type:NONCLUSTERED|space:PRIMARY|disabled:0|hypothetical:0|fill:0|padded:0|ignoredup:0|rowlocks:1|pagelocks:1|seq:0|statsnorecompute:0|K:ExternalId:D"] }];
        yield return [exact with { UnexpectedSurfaceCount = 1 }];
    }

    [Theory]
    [MemberData(nameof(SchemaDriftCases))]
    public void CurrentEfModelReady_RejectsEveryRelationalContractDrift(
        ExactDatabaseSchemaSnapshot drifted)
    {
        var action = () => ExactDatabaseSchemaContract.AssertExact(CreateExactSchema(), drifted);

        action.Should().Throw<InvalidOperationException>()
            .WithMessage("*does not exactly match the reviewed current EF relational model*");
    }

    [Fact]
    public void CurrentEfModelReady_AcceptsOnlyTheExactRelationalContract()
    {
        var exact = CreateExactSchema();

        var action = () => ExactDatabaseSchemaContract.AssertExact(exact, exact);

        action.Should().NotThrow();
    }

    [Fact]
    public void RuntimeAuthority_AcceptsOnlyExactExpectedPrincipalsAndRolesAtCompletion()
    {
        var expected = CreateExpectedPrincipals();
        var observed = CreateExactObservedPrincipals();

        var action = () => ExactDatabaseAuthorityContract.AssertExactOrRecoverablePrefix(
            expected,
            observed,
            recoverableIncompletePrincipalName: null,
            allowAllRecoverablePrefixes: false,
            requireAllExpectedPrincipals: true,
            unexpectedRoleMembershipCount: 0,
            unexpectedDirectPermissionCount: 0);

        action.Should().NotThrow();
    }

    [Fact]
    public void RuntimeAuthority_AllowsOnlyARecognizedLeastPrivilegePrefixDuringRecovery()
    {
        var expected = CreateExpectedPrincipals();
        var observed = new[]
        {
            CreateExactObservedPrincipals()[0] with { Roles = ["db_datareader"] }
        };

        var action = () => ExactDatabaseAuthorityContract.AssertExactOrRecoverablePrefix(
            expected,
            observed,
            recoverableIncompletePrincipalName: observed[0].Name,
            allowAllRecoverablePrefixes: false,
            requireAllExpectedPrincipals: false,
            unexpectedRoleMembershipCount: 0,
            unexpectedDirectPermissionCount: 0);

        action.Should().NotThrow();
    }

    [Fact]
    public void RuntimeAuthority_AllowsApiMetadataGrantCrashOnlyDuringRecovery()
    {
        var observed = new[]
        {
            CreateExactObservedPrincipals()[0] with
            {
                Roles = [],
                DirectPermissionCount = 0
            }
        };

        var recovery = () => ExactDatabaseAuthorityContract.AssertExactOrRecoverablePrefix(
            CreateExpectedPrincipals(),
            observed,
            recoverableIncompletePrincipalName: observed[0].Name,
            allowAllRecoverablePrefixes: false,
            requireAllExpectedPrincipals: false,
            unexpectedRoleMembershipCount: 0,
            unexpectedDirectPermissionCount: 0);
        var completion = () => ExactDatabaseAuthorityContract.AssertExactOrRecoverablePrefix(
            CreateExpectedPrincipals(),
            observed,
            recoverableIncompletePrincipalName: null,
            allowAllRecoverablePrefixes: false,
            requireAllExpectedPrincipals: true,
            unexpectedRoleMembershipCount: 0,
            unexpectedDirectPermissionCount: 0);

        recovery.Should().NotThrow();
        completion.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void RuntimeAuthority_AllowsAWorkerRoleGrantCrashToReachItsFinalRepairPass()
    {
        var observed = CreateExactObservedPrincipals()
            .Select((item, index) => index == 1 ? item with { Roles = ["db_datareader"] } : item)
            .ToArray();

        var action = () => ExactDatabaseAuthorityContract.AssertExactOrRecoverablePrefix(
            CreateExpectedPrincipals(),
            observed,
            recoverableIncompletePrincipalName: null,
            allowAllRecoverablePrefixes: true,
            requireAllExpectedPrincipals: false,
            unexpectedRoleMembershipCount: 0,
            unexpectedDirectPermissionCount: 0);

        action.Should().NotThrow();
    }

    public static IEnumerable<object[]> DatabaseAuthorityDriftCases()
    {
        var exact = CreateExactObservedPrincipals();
        yield return [exact.Append(exact[0] with { Name = "rogue" }).ToArray(), false, 0, 0];
        yield return [exact.Select((item, index) => index == 0 ? item with { ClientId = Guid.NewGuid() } : item).ToArray(), false, 0, 0];
        yield return [exact.Select((item, index) => index == 0 ? item with { Type = "S" } : item).ToArray(), false, 0, 0];
        yield return [exact.Select((item, index) => index == 0 ? item with { Roles = ["db_owner"] } : item).ToArray(), false, 0, 0];
        yield return [exact.Select((item, index) => index == 0 ? item with { Roles = ["db_datareader"] } : item).ToArray(), false, 0, 0];
        yield return [exact.Select((item, index) => index == 0 ? item with { DirectPermissionCount = 2 } : item).ToArray(), false, 0, 0];
        yield return [exact.Select((item, index) => index == 0 ? item with { OwnedSchemaCount = 1 } : item).ToArray(), false, 0, 0];
        yield return [exact.Take(1).ToArray(), true, 0, 0];
        yield return [exact, false, 1, 0];
        yield return [exact, false, 0, 1];
    }

    [Theory]
    [MemberData(nameof(DatabaseAuthorityDriftCases))]
    public void RuntimeAuthority_RejectsIdentityOrAuthorityDrift(
        IReadOnlyCollection<ObservedDatabasePrincipal> observed,
        bool requireAll,
        int unexpectedMemberships,
        int unexpectedPermissions)
    {
        var action = () => ExactDatabaseAuthorityContract.AssertExactOrRecoverablePrefix(
            CreateExpectedPrincipals(),
            observed,
            recoverableIncompletePrincipalName: null,
            allowAllRecoverablePrefixes: false,
            requireAllExpectedPrincipals: requireAll,
            unexpectedRoleMembershipCount: unexpectedMemberships,
            unexpectedDirectPermissionCount: unexpectedPermissions);

        action.Should().Throw<InvalidOperationException>();
    }

    private static ExactDatabaseSchemaSnapshot CreateExactSchema() => new(
        ["dbo.Agents|temporal:0|memory:0|durability:SCHEMA_AND_DATA|lobspace:-|filestreamspace:-|external:0|filetable:0|node:0|edge:0|ledger:0|lock:TABLE|lockbulk:0|largeout:0|replicated:0|merge:0|syncrepl:0|cdc:0|archive:0|ansinulls:1|replfilter:0"],
        ["dbo.Agents|Id|uniqueidentifier|0|default:-|computed:-|stored:0|identity:0:-:-:nfr:0|rowversion:0|generated:0|sparse:0|columnset:0|filestream:0|collation:-|encrypted:0:-:-|masked:0:-|hidden:0|xml:0:0|rule:0"],
        ["dbo.Agents|PK_Agents|Id:A|type:CLUSTERED|space:PRIMARY|disabled:0|hypothetical:0|fill:0|padded:0|ignoredup:0|rowlocks:1|pagelocks:1|seq:0|statsnorecompute:0"],
        [],
        [],
        ["dbo.Agents|CK_Agents_Id|id<>0|disabled:0|untrusted:0"],
        ["dbo.Agents|IX_Agents_Id|unique:1|filter:-|type:NONCLUSTERED|space:PRIMARY|disabled:0|hypothetical:0|fill:0|padded:0|ignoredup:0|rowlocks:1|pagelocks:1|seq:0|statsnorecompute:0|K:Id:A"],
        0);

    private static PristineDatabaseSurfaceSnapshot CreatePristineSurface() =>
        new(
            0,
            UnexpectedDatabaseSurfaceTelemetry.FromOrderedCounts(
                CreateZeroCatalogCounts(),
                CreateZeroProgrammableObjectTypeCounts()),
            0,
            0,
            0,
            DatabaseDirectPermissionTelemetry.FromCounts(0, 2, 2, 0, 2),
            0,
            0);

    private static int[] CreateZeroCatalogCounts() =>
        new int[UnexpectedDatabaseSurfaceTelemetry.ExpectedCategoryCount];

    private static int[] CreateZeroProgrammableObjectTypeCounts() =>
        new int[UnexpectedDatabaseSurfaceTelemetry.ExpectedProgrammableObjectTypeCount];

    private static ExpectedDatabasePrincipal[] CreateExpectedPrincipals() =>
    [
        new("ca-gateway-api-dev", Guid.Parse("11111111-1111-4111-8111-111111111111"), 1),
        new("ca-gateway-worker-dev-v3", Guid.Parse("22222222-2222-4222-8222-222222222222"), 0)
    ];

    private static ObservedDatabasePrincipal[] CreateExactObservedPrincipals() =>
        CreateExpectedPrincipals()
            .Select(item => new ObservedDatabasePrincipal(
                item.Name,
                item.ClientId,
                "E",
                ["db_datareader", "db_datawriter"],
                item.ExpectedDirectPermissionCount,
                0,
                0))
            .ToArray();
}
