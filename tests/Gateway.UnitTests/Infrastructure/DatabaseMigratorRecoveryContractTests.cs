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
        DatabaseBootstrapRecoveryContract.ClassifyPristineReadiness(CreatePristineSurface())
            .Should().Be(PristineDatabaseSurfaceReadiness.Ready);
    }

    [Fact]
    public void Initialization_AllowsOnlyTheSoleAuditSpecificationMismatchToWait()
    {
        var surface = CreateSurfaceWithCatalogCounts(("databaseAuditSpecifications", 1));

        DatabaseBootstrapRecoveryContract.ClassifyPristineReadiness(surface)
            .Should().Be(PristineDatabaseSurfaceReadiness.AuditSpecificationPending);
        surface.CatalogSurface.DatabaseAuditSpecificationMismatchCount.Should().Be(1);
    }

    [Fact]
    public void Initialization_RejectsAuditWaitForMixedOrOtherPristineMismatches()
    {
        var auditPending = CreateSurfaceWithCatalogCounts(("databaseAuditSpecifications", 1));
        PristineDatabaseSurfaceSnapshot[] rejected =
        [
            auditPending with { UserTableCount = 1 },
            auditPending with { UnexpectedSchemaCount = 1 },
            auditPending with { DirectPermissions = CreatePermissionTelemetry(1, 2, 1, 0, 0, 1, 1) },
            CreateSurfaceWithCatalogCounts(("databaseAuditSpecifications", 2)),
            CreateSurfaceWithCatalogCounts(("databaseAuditSpecifications", 1), ("securityPolicies", 1)),
            CreateSurfaceWithCatalogCounts(("securityPolicies", 1))
        ];

        foreach (var surface in rejected)
        {
            var action = () => DatabaseBootstrapRecoveryContract.ClassifyPristineReadiness(surface);

            action.Should().Throw<InvalidOperationException>()
                .WithMessage("*requires a pristine database surface*");
        }
    }

    [Fact]
    public void AuditSpecificationReadiness_AcceptsOnlyTheExactReadyTuple()
    {
        var snapshot = new AzureSqlAuditSpecificationReadinessSnapshot(1, 1, 1, 0, 0, 0, 1, 0);

        DatabaseBootstrapRecoveryContract.ClassifyAuditSpecificationReadiness(snapshot)
            .Should().Be(AzureSqlAuditSpecificationReadiness.Ready);
    }

    [Theory]
    [InlineData(0, 0, 0, 0, 0, 0, 0, 0)]
    [InlineData(1, 1, 0, 1, 0, 0, 1, 0)]
    [InlineData(1, 1, 1, 0, 1, 0, 0, 0)]
    [InlineData(1, 1, 1, 0, 0, 1, 0, 0)]
    public void AuditSpecificationReadiness_AllowsOnlyInternallyConsistentBoundedPendingTuples(
        int total,
        int expectedNameHashMatches,
        int enabled,
        int disabled,
        int nullGuid,
        int zeroGuid,
        int nonzeroGuid,
        int details)
    {
        var snapshot = new AzureSqlAuditSpecificationReadinessSnapshot(
            total,
            expectedNameHashMatches,
            enabled,
            disabled,
            nullGuid,
            zeroGuid,
            nonzeroGuid,
            details);

        DatabaseBootstrapRecoveryContract.ClassifyAuditSpecificationReadiness(snapshot)
            .Should().Be(AzureSqlAuditSpecificationReadiness.Pending);
    }

    public static IEnumerable<object[]> InvalidAuditSpecificationReadinessTuples()
    {
        yield return [new AzureSqlAuditSpecificationReadinessSnapshot(2, 2, 2, 0, 0, 0, 2, 0)];
        yield return [new AzureSqlAuditSpecificationReadinessSnapshot(1, 0, 1, 0, 0, 0, 1, 0)];
        yield return [new AzureSqlAuditSpecificationReadinessSnapshot(1, 1, 1, 0, 0, 0, 1, 1)];
        yield return [new AzureSqlAuditSpecificationReadinessSnapshot(1, 1, 0, 0, 0, 0, 1, 0)];
        yield return [new AzureSqlAuditSpecificationReadinessSnapshot(1, 1, 1, 1, 0, 0, 1, 0)];
        yield return [new AzureSqlAuditSpecificationReadinessSnapshot(1, 1, 1, 0, 0, 0, 0, 0)];
        yield return [new AzureSqlAuditSpecificationReadinessSnapshot(1, 1, 1, 0, 1, 0, 1, 0)];
        yield return [new AzureSqlAuditSpecificationReadinessSnapshot(-1, 0, 0, 0, 0, 0, 0, 0)];
    }

    [Theory]
    [MemberData(nameof(InvalidAuditSpecificationReadinessTuples))]
    public void AuditSpecificationReadiness_RejectsMultiplicityWrongHashDetailsAndInconsistentPartitions(
        AzureSqlAuditSpecificationReadinessSnapshot snapshot)
    {
        var action = () => DatabaseBootstrapRecoveryContract.ClassifyAuditSpecificationReadiness(snapshot);

        action.Should().Throw<InvalidOperationException>()
            .WithMessage("*outside the exact bounded transition*safe counts were *");
    }

    [Fact]
    public async Task AuditSpecificationConvergence_ReturnsImmediatelyWhenReady()
    {
        var readCount = 0;
        var delayCount = 0;
        var elapsed = TimeSpan.Zero;

        await AzureSqlAuditSpecificationConvergence.WaitAsync(
            token =>
            {
                token.CanBeCanceled.Should().BeTrue();
                readCount++;
                return Task.FromResult(ReadyAuditSpecificationSnapshot());
            },
            timeout: TimeSpan.FromSeconds(10),
            retryDelay: TimeSpan.FromSeconds(1),
            elapsedProvider: () => elapsed,
            delayAsync: (delay, token) =>
            {
                delayCount++;
                elapsed += delay;
                return Task.CompletedTask;
            });

        readCount.Should().Be(1);
        delayCount.Should().Be(0);
        elapsed.Should().Be(TimeSpan.Zero);
    }

    [Fact]
    public async Task AuditSpecificationConvergence_RetriesPendingUntilReady()
    {
        var readCount = 0;
        var delayCount = 0;
        var elapsed = TimeSpan.Zero;

        await AzureSqlAuditSpecificationConvergence.WaitAsync(
            token =>
            {
                token.CanBeCanceled.Should().BeTrue();
                readCount++;
                return Task.FromResult(
                    readCount == 1
                        ? PendingAuditSpecificationSnapshot()
                        : ReadyAuditSpecificationSnapshot());
            },
            timeout: TimeSpan.FromSeconds(10),
            retryDelay: TimeSpan.FromSeconds(1),
            elapsedProvider: () => elapsed,
            delayAsync: (delay, token) =>
            {
                token.CanBeCanceled.Should().BeTrue();
                delayCount++;
                elapsed += delay;
                return Task.CompletedTask;
            });

        readCount.Should().Be(2);
        delayCount.Should().Be(1);
        elapsed.Should().Be(TimeSpan.FromSeconds(1));
    }

    [Fact]
    public async Task AuditSpecificationConvergence_RejectsUnsafeStateWithoutRetry()
    {
        var readCount = 0;
        var delayCount = 0;
        var unsafeSnapshot = new AzureSqlAuditSpecificationReadinessSnapshot(1, 0, 1, 0, 0, 0, 1, 0);

        var action = () => AzureSqlAuditSpecificationConvergence.WaitAsync(
            token =>
            {
                readCount++;
                return Task.FromResult(unsafeSnapshot);
            },
            timeout: TimeSpan.FromSeconds(10),
            retryDelay: TimeSpan.FromSeconds(1),
            elapsedProvider: () => TimeSpan.Zero,
            delayAsync: (delay, token) =>
            {
                delayCount++;
                return Task.CompletedTask;
            });

        await action.Should().ThrowAsync<InvalidOperationException>()
            .WithMessage("*outside the exact bounded transition*");
        readCount.Should().Be(1);
        delayCount.Should().Be(0);
    }

    [Fact]
    public async Task AuditSpecificationConvergence_FailsClosedAtTheMonotonicDeadline()
    {
        var readCount = 0;
        var delayCount = 0;
        var elapsed = TimeSpan.Zero;

        var action = () => AzureSqlAuditSpecificationConvergence.WaitAsync(
            token =>
            {
                readCount++;
                elapsed += TimeSpan.FromSeconds(3);
                return Task.FromResult(PendingAuditSpecificationSnapshot());
            },
            timeout: TimeSpan.FromSeconds(10),
            retryDelay: TimeSpan.FromSeconds(5),
            elapsedProvider: () => elapsed,
            delayAsync: (delay, token) =>
            {
                delayCount++;
                elapsed += delay;
                return Task.CompletedTask;
            });

        await action.Should().ThrowAsync<TimeoutException>()
            .WithMessage("*bounded monotonic deadline*safe counts were *");
        readCount.Should().Be(2);
        delayCount.Should().Be(1);
        elapsed.Should().Be(TimeSpan.FromSeconds(11));
    }

    [Fact]
    public async Task AuditSpecificationConvergence_PropagatesCallerCancellation()
    {
        using var cancellation = new CancellationTokenSource();
        var readCount = 0;
        var delayCount = 0;

        var action = () => AzureSqlAuditSpecificationConvergence.WaitAsync(
            token =>
            {
                token.CanBeCanceled.Should().BeTrue();
                readCount++;
                return Task.FromResult(PendingAuditSpecificationSnapshot());
            },
            timeout: TimeSpan.FromSeconds(10),
            retryDelay: TimeSpan.FromSeconds(1),
            elapsedProvider: () => TimeSpan.Zero,
            delayAsync: (delay, token) =>
            {
                delayCount++;
                cancellation.Cancel();
                return Task.Delay(delay, token);
            },
            cancellationToken: cancellation.Token);

        await action.Should().ThrowAsync<OperationCanceledException>();
        readCount.Should().Be(1);
        delayCount.Should().Be(1);
    }

    [Fact]
    public async Task AuditSpecificationConvergence_PropagatesReaderErrorsWithoutRetry()
    {
        var readCount = 0;
        var delayCount = 0;
        var readerError = new InvalidOperationException("Safe synthetic reader failure.");

        var action = () => AzureSqlAuditSpecificationConvergence.WaitAsync(
            token =>
            {
                readCount++;
                return Task.FromException<AzureSqlAuditSpecificationReadinessSnapshot>(readerError);
            },
            timeout: TimeSpan.FromSeconds(10),
            retryDelay: TimeSpan.FromSeconds(1),
            elapsedProvider: () => TimeSpan.Zero,
            delayAsync: (delay, token) =>
            {
                delayCount++;
                return Task.CompletedTask;
            });

        var exception = await action.Should().ThrowAsync<InvalidOperationException>();
        exception.Which.Should().BeSameAs(readerError);
        readCount.Should().Be(1);
        delayCount.Should().Be(0);
    }

    public static IEnumerable<object[]> NonPristineDatabaseSurfaces()
    {
        var pristine = CreatePristineSurface();
        yield return [pristine with { UserTableCount = 1 }];
        yield return [pristine with { UnexpectedSchemaCount = 1 }];
        yield return [pristine with { UnexpectedPrincipalCount = 1 }];
        yield return [pristine with { RoleMembershipCount = 1 }];
        yield return [pristine with { DirectPermissions = CreatePermissionTelemetry(1, 3, 2, 1, 2, 0, 1) }];
        yield return [pristine with { DirectPermissions = CreatePermissionTelemetry(0, 1, 1, 0, 1, 0, 0) }];
        yield return [pristine with { DirectPermissions = CreatePermissionTelemetry(0, 3, 3, 0, 3, 0, 0) }];
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
            CreatePermissionTelemetry(6, 8, 2, 1, 2, 0, 6),
            7,
            8);

        var action = () => DatabaseBootstrapRecoveryContract.AssertPristine(surface);

        var exception = action.Should().Throw<InvalidOperationException>().Which;
        exception.Message.Should().StartWith(
            "Clean bootstrap requires a pristine database surface before its durable initialization marker is written; " +
            "safe counts were tables=1, objects=2, ");
        exception.Message.Should().Contain("schemas=3, principals=4, roleMemberships=5, directPermissions=7, ");
        exception.Message.Should().Contain(
            $"directPermissionTelemetry=[{surface.DirectPermissions.ToSafeSummary()}], options=7, ownerMismatch=8.");
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
        string[] permissionFields =
        [
            "rawNonWhitelistedDirectPermissions", "positiveIdPublicSelectTargets",
            "positiveIdPublicSelectMsShippedObjectTargets",
            "positiveIdPublicSelectNonMsShippedProgrammableObjectCorrelations",
            "positiveIdPublicSelectMsShippedSystemCatalogTargets",
            "positiveIdPublicSelectMsShippedDatabaseObjectOnlyTargets",
            "positiveIdPublicSelectNonMsShippedOrUnresolvedTargets",
            "rawClassDatabasePermissions", "rawClassObjectOrColumnPermissions", "rawClassOtherPermissions",
            "rawStateGrantPermissions", "rawStateGrantWithGrantOptionPermissions", "rawStateDenyPermissions",
            "rawStateRevokePermissions", "rawStateOtherPermissions",
            "rawGranteePublicPermissions", "rawGranteeGuestPermissions", "rawGranteeDboPermissions",
            "rawGranteeFixedRolePermissions", "rawGranteeOtherPermissions",
            "rawPermissionNameConnect", "rawPermissionNameSelect", "rawPermissionNameViewDefinition",
            "rawPermissionNameViewAnyColumnMasterKeyDefinition",
            "rawPermissionNameViewAnyColumnEncryptionKeyDefinition", "rawPermissionNameOther",
            "rawAddressDatabase", "rawAddressNegativeObject", "rawAddressZeroObject",
            "rawAddressPositiveObject", "rawAddressColumn", "rawAddressOther",
            "rawGrantorDbo", "rawGrantorOther",
            "positiveIdPublicSelectTypeAggregateFunctions", "positiveIdPublicSelectTypeCheckConstraints",
            "positiveIdPublicSelectTypeDefaultConstraints", "positiveIdPublicSelectTypeEdgeConstraints",
            "positiveIdPublicSelectTypeExternalTables", "positiveIdPublicSelectTypeForeignKeys",
            "positiveIdPublicSelectTypeSqlScalarFunctions", "positiveIdPublicSelectTypeClrScalarFunctions",
            "positiveIdPublicSelectTypeClrTableValuedFunctions",
            "positiveIdPublicSelectTypeSqlInlineTableValuedFunctions",
            "positiveIdPublicSelectTypeInternalTables", "positiveIdPublicSelectTypeSqlStoredProcedures",
            "positiveIdPublicSelectTypeClrStoredProcedures", "positiveIdPublicSelectTypePlanGuides",
            "positiveIdPublicSelectTypePrimaryKeys", "positiveIdPublicSelectTypeRules",
            "positiveIdPublicSelectTypeReplicationFilterProcedures",
            "positiveIdPublicSelectTypeSystemTables", "positiveIdPublicSelectTypeSynonyms",
            "positiveIdPublicSelectTypeSequences", "positiveIdPublicSelectTypeServiceQueues",
            "positiveIdPublicSelectTypeStatisticsTrees", "positiveIdPublicSelectTypeClrDmlTriggers",
            "positiveIdPublicSelectTypeSqlTableValuedFunctions",
            "positiveIdPublicSelectTypeSqlDmlTriggers", "positiveIdPublicSelectTypeTableTypes",
            "positiveIdPublicSelectTypeUserTables", "positiveIdPublicSelectTypeUniqueConstraints",
            "positiveIdPublicSelectTypeViews", "positiveIdPublicSelectTypeExtendedStoredProcedures",
            "positiveIdPublicSelectTypeOtherOrUnresolved",
            "positiveIdPublicSelectSchemaSys", "positiveIdPublicSelectSchemaDbo",
            "positiveIdPublicSelectSchemaOtherOrUnresolved",
            "positiveIdPublicSelectParentless", "positiveIdPublicSelectParented",
            "positiveIdPublicSelectParentUnresolved",
            "positiveIdPublicSelectInViews", "positiveIdPublicSelectInProcedures",
            "positiveIdPublicSelectInSqlModules", "positiveIdPublicSelectInTables",
            "positiveIdPublicSelectInInternalTables", "positiveIdPublicSelectInSequences",
            "positiveIdPublicSelectInSynonyms", "positiveIdPublicSelectInTriggers",
            "positiveIdPublicSelectWithSpecializedCatalogMembership",
            "positiveIdPublicSelectWithoutSpecializedCatalogMembership"
        ];
        string[] pristineOnlyFields =
        [
            "userTables", "unexpectedSchemas", "unexpectedPrincipals", "unexpectedRoleMemberships",
            .. permissionFields,
            "unsafeDatabaseOptions", "databaseOwnerMismatches"
        ];

        UnexpectedDatabaseSurfaceTelemetry.SqlFieldNames.Should().Equal(catalogFields);
        DatabaseDirectPermissionTelemetry.SqlFieldNames.Should().Equal(permissionFields);
        DatabaseDirectPermissionTelemetry.ExpectedFieldCount.Should().Be(permissionFields.Length);
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
    [InlineData(0, 1, 1, 0, 0, 1, 0, 0)]
    [InlineData(1, 1, 1, 0, 0, 1, 0, 1)]
    [InlineData(1, 3, 2, 1, 2, 0, 1, 2)]
    [InlineData(0, 1, 1, 0, 1, 0, 0, 1)]
    [InlineData(0, 2, 2, 0, 0, 2, 0, 1)]
    [InlineData(0, 3, 3, 0, 3, 0, 0, 1)]
    public void DirectPermissionTelemetry_PreservesExactDatabaseFirewallViewSelectBaseline(
        int rawNonWhitelisted,
        int positiveIdTargets,
        int positiveIdMsShippedObjectTargets,
        int positiveIdNonMsShippedProgrammableObjectCorrelations,
        int positiveIdMsShippedSystemCatalogTargets,
        int positiveIdMsShippedDatabaseObjectOnlyTargets,
        int positiveIdNonMsShippedOrUnresolvedTargets,
        int expectedUnexpected)
    {
        var telemetry = CreatePermissionTelemetry(
            rawNonWhitelisted,
            positiveIdTargets,
            positiveIdMsShippedObjectTargets,
            positiveIdNonMsShippedProgrammableObjectCorrelations,
            positiveIdMsShippedSystemCatalogTargets,
            positiveIdMsShippedDatabaseObjectOnlyTargets,
            positiveIdNonMsShippedOrUnresolvedTargets);

        telemetry.UnexpectedCount.Should().Be(expectedUnexpected);
        telemetry.ToSafeSummary().Should().Be(
            string.Join(',', telemetry.Counts.Select(item => $"{item.Category}={item.Count}")));
    }

    [Fact]
    public void DirectPermissionTelemetry_RejectsGw26LiveTupleAndAllObjectTargetSubstitution()
    {
        var gw26Live = CreatePermissionTelemetry(1, 1, 1, 0, 0, 1, 0);
        var allObjectSubstitution = CreatePermissionTelemetry(0, 2, 2, 0, 0, 2, 0);

        gw26Live.UnexpectedCount.Should().Be(1);
        allObjectSubstitution.UnexpectedCount.Should().Be(1);
        var liveAction = () => DatabaseBootstrapRecoveryContract.AssertPristine(
            CreatePristineSurface() with { DirectPermissions = gw26Live });
        var substitutionAction = () => DatabaseBootstrapRecoveryContract.AssertPristine(
            CreatePristineSurface() with { DirectPermissions = allObjectSubstitution });
        liveAction.Should().Throw<InvalidOperationException>();
        substitutionAction.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void DirectPermissionTelemetry_ReportsFixedRawAndPositiveTargetDimensionsWithoutIdentifiers()
    {
        var counts = CreatePermissionCounts(1, 1, 1, 0, 0, 1, 0);
        SetPermissionCount(counts, "rawGranteeOtherPermissions", 0);
        SetPermissionCount(counts, "rawGranteePublicPermissions", 1);
        SetPermissionCount(counts, "rawPermissionNameOther", 0);
        SetPermissionCount(counts, "rawPermissionNameViewAnyColumnEncryptionKeyDefinition", 1);
        SetPermissionCount(counts, "rawGrantorOther", 0);
        SetPermissionCount(counts, "rawGrantorDbo", 1);
        SetPermissionCount(counts, "positiveIdPublicSelectTypeOtherOrUnresolved", 0);
        SetPermissionCount(counts, "positiveIdPublicSelectTypeViews", 1);
        SetPermissionCount(counts, "positiveIdPublicSelectSchemaOtherOrUnresolved", 0);
        SetPermissionCount(counts, "positiveIdPublicSelectSchemaSys", 1);
        SetPermissionCount(counts, "positiveIdPublicSelectParentUnresolved", 0);
        SetPermissionCount(counts, "positiveIdPublicSelectParentless", 1);
        SetPermissionCount(counts, "positiveIdPublicSelectWithoutSpecializedCatalogMembership", 0);
        SetPermissionCount(counts, "positiveIdPublicSelectWithSpecializedCatalogMembership", 1);
        SetPermissionCount(counts, "positiveIdPublicSelectInViews", 1);
        SetPermissionCount(counts, "positiveIdPublicSelectInSqlModules", 1);

        var telemetry = DatabaseDirectPermissionTelemetry.FromOrderedCounts(counts);

        telemetry.UnexpectedCount.Should().Be(1);
        telemetry.ToSafeSummary().Should().Contain("rawGranteePublicPermissions=1");
        telemetry.ToSafeSummary().Should().Contain("rawPermissionNameViewAnyColumnEncryptionKeyDefinition=1");
        telemetry.ToSafeSummary().Should().Contain("rawGrantorDbo=1");
        telemetry.ToSafeSummary().Should().Contain("positiveIdPublicSelectMsShippedDatabaseObjectOnlyTargets=1");
        telemetry.ToSafeSummary().Should().Contain("positiveIdPublicSelectTypeViews=1");
        telemetry.ToSafeSummary().Should().Contain("positiveIdPublicSelectSchemaSys=1");
        telemetry.ToSafeSummary().Should().Contain("positiveIdPublicSelectParentless=1");
        telemetry.ToSafeSummary().Should().Contain("positiveIdPublicSelectInViews=1");
        telemetry.ToSafeSummary().Should().NotContain("object_id");
        telemetry.ToSafeSummary().Should().NotContain("principal_id");
        telemetry.ToSafeSummary().Should().NotContain("sid=");
    }

    public static IEnumerable<object[]> PermissionExactPartitionFields()
    {
        yield return ["rawClassOtherPermissions"];
        yield return ["rawStateOtherPermissions"];
        yield return ["rawGranteePublicPermissions"];
        yield return ["rawPermissionNameConnect"];
        yield return ["rawAddressOther"];
        yield return ["rawGrantorDbo"];
        yield return ["positiveIdPublicSelectTypeViews"];
        yield return ["positiveIdPublicSelectSchemaDbo"];
        yield return ["positiveIdPublicSelectParented"];
    }

    [Theory]
    [MemberData(nameof(PermissionExactPartitionFields))]
    public void DirectPermissionTelemetry_RejectsEveryInconsistentExactPartition(string fieldName)
    {
        var counts = CreatePermissionCounts(0, 2, 2, 0, 2, 0, 0);
        SetPermissionCount(counts, fieldName, 1);

        var action = () => DatabaseDirectPermissionTelemetry.FromOrderedCounts(counts);

        action.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void DirectPermissionTelemetry_RejectsWrongCardinalityNegativeAndInconsistentSubsets()
    {
        var valid = CreatePermissionCounts(0, 2, 2, 0, 2, 0, 0);
        var negative = valid.ToArray();
        negative[0] = -1;
        var shippedExceedsTotal = CreatePermissionCounts(0, 1, 1, 0, 1, 0, 0);
        SetPermissionCount(shippedExceedsTotal, "positiveIdPublicSelectMsShippedObjectTargets", 2);
        var programmableExceedsRaw = CreatePermissionCounts(0, 3, 2, 0, 2, 0, 1);
        SetPermissionCount(programmableExceedsRaw,
            "positiveIdPublicSelectNonMsShippedProgrammableObjectCorrelations", 1);
        var inconsistentOrigin = CreatePermissionCounts(0, 2, 2, 0, 2, 0, 0);
        SetPermissionCount(inconsistentOrigin, "positiveIdPublicSelectMsShippedSystemCatalogTargets", 1);
        SetPermissionCount(inconsistentOrigin, "positiveIdPublicSelectMsShippedDatabaseObjectOnlyTargets", 0);
        var specializedCorrelationWithoutUnion = CreatePermissionCounts(0, 2, 2, 0, 2, 0, 0);
        SetPermissionCount(specializedCorrelationWithoutUnion, "positiveIdPublicSelectInViews", 1);
        var unionWithoutCorrelation = CreatePermissionCounts(0, 2, 2, 0, 2, 0, 0);
        SetPermissionCount(unionWithoutCorrelation,
            "positiveIdPublicSelectWithoutSpecializedCatalogMembership", 1);
        SetPermissionCount(unionWithoutCorrelation,
            "positiveIdPublicSelectWithSpecializedCatalogMembership", 1);

        Action[] actions =
        [
            () => DatabaseDirectPermissionTelemetry.FromOrderedCounts(valid[..^1]),
            () => DatabaseDirectPermissionTelemetry.FromOrderedCounts(negative),
            () => DatabaseDirectPermissionTelemetry.FromOrderedCounts(shippedExceedsTotal),
            () => DatabaseDirectPermissionTelemetry.FromOrderedCounts(programmableExceedsRaw),
            () => DatabaseDirectPermissionTelemetry.FromOrderedCounts(inconsistentOrigin),
            () => DatabaseDirectPermissionTelemetry.FromOrderedCounts(specializedCorrelationWithoutUnion),
            () => DatabaseDirectPermissionTelemetry.FromOrderedCounts(unionWithoutCorrelation)
        ];
        foreach (var action in actions)
            action.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void DirectPermissionTelemetry_RejectsCheckedTotalsAndUnexpectedCountOverflow()
    {
        var unexpectedCountOverflow = CreatePermissionCounts(int.MaxValue, 0, 0, 0, 0, 0, 0);
        var rawPartitionOverflow = CreatePermissionCounts(0, 0, 0, 0, 0, 0, 0);
        SetPermissionCount(rawPartitionOverflow, "rawClassDatabasePermissions", int.MaxValue);
        SetPermissionCount(rawPartitionOverflow, "rawClassObjectOrColumnPermissions", 1);
        var typePartitionOverflow = CreatePermissionCounts(0, 0, 0, 0, 0, 0, 0);
        SetPermissionCount(typePartitionOverflow, "positiveIdPublicSelectTypeAggregateFunctions", int.MaxValue);
        SetPermissionCount(typePartitionOverflow, "positiveIdPublicSelectTypeCheckConstraints", 1);
        var specializedCorrelationOverflow = CreatePermissionCounts(0, 0, 0, 0, 0, 0, 0);
        SetPermissionCount(specializedCorrelationOverflow, "positiveIdPublicSelectInViews", int.MaxValue);
        SetPermissionCount(specializedCorrelationOverflow, "positiveIdPublicSelectInProcedures", 1);
        SetPermissionCount(specializedCorrelationOverflow,
            "positiveIdPublicSelectWithSpecializedCatalogMembership", int.MaxValue);
        SetPermissionCount(specializedCorrelationOverflow,
            "positiveIdPublicSelectWithoutSpecializedCatalogMembership", 1);

        Action[] actions =
        [
            () => DatabaseDirectPermissionTelemetry.FromOrderedCounts(unexpectedCountOverflow),
            () => DatabaseDirectPermissionTelemetry.FromOrderedCounts(rawPartitionOverflow),
            () => DatabaseDirectPermissionTelemetry.FromOrderedCounts(typePartitionOverflow),
            () => DatabaseDirectPermissionTelemetry.FromOrderedCounts(specializedCorrelationOverflow)
        ];
        foreach (var action in actions)
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
            CreatePermissionTelemetry(0, 1, 1, 0, 0, 1, 0),
            0,
            0);

    private static AzureSqlAuditSpecificationReadinessSnapshot ReadyAuditSpecificationSnapshot() =>
        new(1, 1, 1, 0, 0, 0, 1, 0);

    private static AzureSqlAuditSpecificationReadinessSnapshot PendingAuditSpecificationSnapshot() =>
        new(0, 0, 0, 0, 0, 0, 0, 0);

    private static PristineDatabaseSurfaceSnapshot CreateSurfaceWithCatalogCounts(
        params (string Category, int Count)[] values)
    {
        var catalogCounts = CreateZeroCatalogCounts();
        foreach (var (category, count) in values)
        {
            var index = UnexpectedDatabaseSurfaceTelemetry.CategoryNames
                .Select((name, ordinal) => (name, ordinal))
                .Single(item => item.name.Equals(category, StringComparison.Ordinal))
                .ordinal;
            catalogCounts[index] = count;
        }

        return CreatePristineSurface() with
        {
            CatalogSurface = UnexpectedDatabaseSurfaceTelemetry.FromOrderedCounts(
                catalogCounts,
                CreateZeroProgrammableObjectTypeCounts())
        };
    }

    private static DatabaseDirectPermissionTelemetry CreatePermissionTelemetry(
        int rawNonWhitelisted,
        int positiveIdTargets,
        int positiveIdMsShippedObjectTargets,
        int positiveIdNonMsShippedProgrammableObjectCorrelations,
        int positiveIdMsShippedSystemCatalogTargets,
        int positiveIdMsShippedDatabaseObjectOnlyTargets,
        int positiveIdNonMsShippedOrUnresolvedTargets) =>
        DatabaseDirectPermissionTelemetry.FromOrderedCounts(
            CreatePermissionCounts(
                rawNonWhitelisted,
                positiveIdTargets,
                positiveIdMsShippedObjectTargets,
                positiveIdNonMsShippedProgrammableObjectCorrelations,
                positiveIdMsShippedSystemCatalogTargets,
                positiveIdMsShippedDatabaseObjectOnlyTargets,
                positiveIdNonMsShippedOrUnresolvedTargets));

    private static int[] CreatePermissionCounts(
        int rawNonWhitelisted,
        int positiveIdTargets,
        int positiveIdMsShippedObjectTargets,
        int positiveIdNonMsShippedProgrammableObjectCorrelations,
        int positiveIdMsShippedSystemCatalogTargets,
        int positiveIdMsShippedDatabaseObjectOnlyTargets,
        int positiveIdNonMsShippedOrUnresolvedTargets)
    {
        var counts = new int[DatabaseDirectPermissionTelemetry.ExpectedFieldCount];
        SetPermissionCount(counts, "rawNonWhitelistedDirectPermissions", rawNonWhitelisted);
        SetPermissionCount(counts, "positiveIdPublicSelectTargets", positiveIdTargets);
        SetPermissionCount(counts, "positiveIdPublicSelectMsShippedObjectTargets",
            positiveIdMsShippedObjectTargets);
        SetPermissionCount(counts, "positiveIdPublicSelectNonMsShippedProgrammableObjectCorrelations",
            positiveIdNonMsShippedProgrammableObjectCorrelations);
        SetPermissionCount(counts, "positiveIdPublicSelectMsShippedSystemCatalogTargets",
            positiveIdMsShippedSystemCatalogTargets);
        SetPermissionCount(counts, "positiveIdPublicSelectMsShippedDatabaseObjectOnlyTargets",
            positiveIdMsShippedDatabaseObjectOnlyTargets);
        SetPermissionCount(counts, "positiveIdPublicSelectNonMsShippedOrUnresolvedTargets",
            positiveIdNonMsShippedOrUnresolvedTargets);

        SetPermissionCount(counts, "rawClassDatabasePermissions", rawNonWhitelisted);
        SetPermissionCount(counts, "rawStateGrantPermissions", rawNonWhitelisted);
        SetPermissionCount(counts, "rawGranteeOtherPermissions", rawNonWhitelisted);
        SetPermissionCount(counts, "rawPermissionNameOther", rawNonWhitelisted);
        SetPermissionCount(counts, "rawAddressDatabase", rawNonWhitelisted);
        SetPermissionCount(counts, "rawGrantorOther", rawNonWhitelisted);
        SetPermissionCount(counts, "positiveIdPublicSelectTypeOtherOrUnresolved", positiveIdTargets);
        SetPermissionCount(counts, "positiveIdPublicSelectSchemaOtherOrUnresolved", positiveIdTargets);
        SetPermissionCount(counts, "positiveIdPublicSelectParentUnresolved", positiveIdTargets);
        SetPermissionCount(counts, "positiveIdPublicSelectWithoutSpecializedCatalogMembership",
            positiveIdTargets);
        return counts;
    }

    private static void SetPermissionCount(int[] counts, string fieldName, int value)
    {
        var index = DatabaseDirectPermissionTelemetry.SqlFieldNames
            .Select((name, ordinal) => (name, ordinal))
            .Single(item => item.name.Equals(fieldName, StringComparison.Ordinal))
            .ordinal;
        counts[index] = value;
    }

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
