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
        yield return [pristine with { UnexpectedObjectCount = 1 }];
        yield return [pristine with { UnexpectedSchemaCount = 1 }];
        yield return [pristine with { UnexpectedPrincipalCount = 1 }];
        yield return [pristine with { RoleMembershipCount = 1 }];
        yield return [pristine with { UnexpectedDirectPermissionCount = 1 }];
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
            .WithMessage("*requires a pristine database surface*");
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
        new(0, 0, 0, 0, 0, 0, 0, 0);

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
