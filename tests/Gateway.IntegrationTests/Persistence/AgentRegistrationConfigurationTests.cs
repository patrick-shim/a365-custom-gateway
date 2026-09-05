using FluentAssertions;
using Gateway.Domain.Entities;
using Gateway.IntegrationTests.Fixtures;
using Microsoft.EntityFrameworkCore;

namespace Gateway.IntegrationTests.Persistence;

public class AgentRegistrationConfigurationTests
{
    [Fact]
    public async Task AgentIdentityObjectIdIndex_ShouldBeUniqueOnlyForActiveProvisionedRegistrations()
    {
        await using var context = TestDbContextFactory.Create();

        var entityType = context.Model.FindEntityType(typeof(AgentRegistration));
        var indexes = entityType!.GetIndexes()
            .Where(index =>
                index.Properties.Count == 1 &&
                index.Properties[0].Name == nameof(AgentRegistration.AgentIdentityObjectId))
            .ToArray();

        indexes.Should().ContainSingle();
        indexes[0].IsUnique.Should().BeTrue();
        indexes[0].GetFilter().Should()
            .Be("[AgentIdentityObjectId] IS NOT NULL AND [IsDeleted] = 0");
    }
}
