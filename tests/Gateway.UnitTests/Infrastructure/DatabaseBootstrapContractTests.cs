using FluentAssertions;
using Gateway.Infrastructure.Persistence;

namespace Gateway.UnitTests.Infrastructure;

public sealed class DatabaseBootstrapContractTests
{
    [Theory]
    [InlineData(1)]
    [InlineData(7)]
    public void Initialization_RejectsAnyExistingUserTable(int tableCount)
    {
        var action = () => DatabaseBootstrapContract.AssertEmptyUserTableCount(tableCount);

        action.Should().Throw<InvalidOperationException>()
            .WithMessage("*exactly zero user tables*");
    }

    [Fact]
    public void Initialization_AcceptsExactlyZeroUserTables()
    {
        var action = () => DatabaseBootstrapContract.AssertEmptyUserTableCount(0);

        action.Should().NotThrow();
    }

    [Fact]
    public void ExactSchema_RejectsAPartialLookalike()
    {
        var expected = new DatabaseSchemaContractSnapshot(
            ["dbo.AgentRegistrations", "dbo.ProvisioningJobs", "dbo.PurviewPolicyProfiles"],
            [
                "dbo.AgentRegistrations|Id|uniqueidentifier|0",
                "dbo.ProvisioningJobs|Id|uniqueidentifier|0",
                "dbo.PurviewPolicyProfiles|Id|uniqueidentifier|0"
            ],
            ["dbo.PurviewPolicyProfiles|IX_PurviewPolicyProfiles_Status|0|Status"],
            0);
        var partial = new DatabaseSchemaContractSnapshot(
            ["dbo.AgentRegistrations", "dbo.ProvisioningJobs"],
            [
                "dbo.AgentRegistrations|Id|uniqueidentifier|0",
                "dbo.ProvisioningJobs|Id|uniqueidentifier|0"
            ],
            [],
            0);

        var action = () => DatabaseBootstrapContract.AssertExactCurrentSchema(expected, partial);

        action.Should().Throw<InvalidOperationException>()
            .WithMessage("*does not exactly match*");
    }

    [Fact]
    public void ExactSchema_RejectsExtraTriggersOrOtherProgrammableObjects()
    {
        var expected = new DatabaseSchemaContractSnapshot(["dbo.AgentRegistrations"], [], [], 0);
        var withTrigger = expected with { ProgrammableObjectCount = 1 };

        var action = () => DatabaseBootstrapContract.AssertExactCurrentSchema(expected, withTrigger);

        action.Should().Throw<InvalidOperationException>();
    }

    [Theory]
    [InlineData("db_owner", 0, 0, 0)]
    [InlineData("", 1, 0, 0)]
    [InlineData("", 0, 1, 0)]
    [InlineData("", 0, 0, 1)]
    public void RuntimePrincipal_RejectsExtraRolesPermissionsAndOwnership(
        string extraRole,
        int directPermissions,
        int ownedSchemas,
        int ownedPrincipals)
    {
        var roles = new List<string> { "db_datareader", "db_datawriter" };
        if (!string.IsNullOrEmpty(extraRole))
            roles.Add(extraRole);

        var action = () => DatabaseBootstrapContract.AssertRuntimePrincipalAuthority(
            roles,
            ["db_datareader", "db_datawriter"],
            directPermissions,
            expectedDirectPermissionCount: 0,
            ownedSchemas,
            ownedPrincipals,
            requireCompleteRoleSet: true);

        action.Should().Throw<InvalidOperationException>();
    }
}
