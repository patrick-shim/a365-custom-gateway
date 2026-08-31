using FluentAssertions;
using Gateway.Infrastructure.Persistence;

namespace Gateway.UnitTests.Infrastructure;

public sealed class DatabaseBootstrapContractTests
{
    private const string ConnectPermission = "G|0|0|0|CONNECT|dbo";
    private const string ViewDefinitionPermission = "G|0|0|0|VIEW DEFINITION|dbo";

    [Fact]
    public void RuntimePrincipal_AcceptsExactApiConnectAndViewDefinitionPermissions()
    {
        var action = () => DatabaseBootstrapContract.AssertRuntimePrincipalAuthority(
            ["db_datareader", "db_datawriter"],
            ["db_datareader", "db_datawriter"],
            [ViewDefinitionPermission, ConnectPermission],
            [ConnectPermission, ViewDefinitionPermission],
            ownedSchemaCount: 0,
            ownedPrincipalCount: 0,
            requireCompleteRoleSet: true);

        action.Should().NotThrow();
    }

    [Fact]
    public void RuntimePrincipal_AcceptsExactWorkerConnectPermission()
    {
        var action = () => DatabaseBootstrapContract.AssertRuntimePrincipalAuthority(
            ["db_datareader", "db_datawriter"],
            ["db_datareader", "db_datawriter"],
            [ConnectPermission],
            [ConnectPermission],
            ownedSchemaCount: 0,
            ownedPrincipalCount: 0,
            requireCompleteRoleSet: true);

        action.Should().NotThrow();
    }

    public static IEnumerable<object[]> RuntimePermissionDriftCases()
    {
        yield return [new[] { "W|0|0|0|CONNECT|dbo" }];
        yield return [new[] { "G|1|0|0|CONNECT|dbo" }];
        yield return [new[] { "G|0|1|0|CONNECT|dbo" }];
        yield return [new[] { "G|0|0|1|CONNECT|dbo" }];
        yield return [new[] { "G|0|0|0|CONNECT|sys" }];
        yield return [new[] { "G|0|0|0|SELECT|dbo" }];
        yield return [new[] { ConnectPermission, ConnectPermission }];
        yield return [new[] { ConnectPermission, "G|0|0|0|SELECT|dbo" }];
        yield return [Array.Empty<string>()];
    }

    [Theory]
    [MemberData(nameof(RuntimePermissionDriftCases))]
    public void RuntimePrincipal_RejectsWrongStateAddressGrantorDuplicateOrSubstitution(
        IReadOnlyCollection<string> observedPermissions)
    {
        var action = () => DatabaseBootstrapContract.AssertRuntimePrincipalAuthority(
            ["db_datareader", "db_datawriter"],
            ["db_datareader", "db_datawriter"],
            observedPermissions,
            [ConnectPermission],
            ownedSchemaCount: 0,
            ownedPrincipalCount: 0,
            requireCompleteRoleSet: true);

        action.Should().Throw<InvalidOperationException>()
            .WithMessage("*unreviewed role, direct permission, or ownership boundary*");
    }

    [Fact]
    public void RuntimePrincipal_RejectsDuplicateExpectedPermissionContract()
    {
        var action = () => DatabaseBootstrapContract.AssertRuntimePrincipalAuthority(
            ["db_datareader", "db_datawriter"],
            ["db_datareader", "db_datawriter"],
            [ConnectPermission],
            [ConnectPermission, ConnectPermission],
            ownedSchemaCount: 0,
            ownedPrincipalCount: 0,
            requireCompleteRoleSet: true);

        action.Should().Throw<InvalidOperationException>();
    }

    [Theory]
    [InlineData("db_owner", false, 0, 0)]
    [InlineData("", true, 0, 0)]
    [InlineData("", false, 1, 0)]
    [InlineData("", false, 0, 1)]
    public void RuntimePrincipal_RejectsExtraRolesPermissionsAndOwnership(
        string extraRole,
        bool addDirectPermission,
        int ownedSchemas,
        int ownedPrincipals)
    {
        var roles = new List<string> { "db_datareader", "db_datawriter" };
        if (!string.IsNullOrEmpty(extraRole))
            roles.Add(extraRole);
        var directPermissions = new List<string> { ConnectPermission };
        if (addDirectPermission)
            directPermissions.Add(ViewDefinitionPermission);

        var action = () => DatabaseBootstrapContract.AssertRuntimePrincipalAuthority(
            roles,
            ["db_datareader", "db_datawriter"],
            directPermissions,
            [ConnectPermission],
            ownedSchemas,
            ownedPrincipals,
            requireCompleteRoleSet: true);

        action.Should().Throw<InvalidOperationException>();
    }
}
