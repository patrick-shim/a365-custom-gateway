using FluentAssertions;
using Gateway.Application.Agents.Queries;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using NSubstitute;

namespace Gateway.UnitTests.Handlers;

public sealed class ListAgentIdentityBlueprintsHandlerTests
{
    private readonly IAgentIdentityBlueprintCatalog _catalog =
        Substitute.For<IAgentIdentityBlueprintCatalog>();

    [Fact]
    public async Task Handle_Should_MapQualifiedBlueprintIdentifiers()
    {
        var objectId = Guid.NewGuid();
        var clientId = Guid.NewGuid();
        _catalog.ListAsync(Arg.Any<CancellationToken>())
            .Returns([
                new AgentIdentityBlueprintCatalogItem(
                    objectId,
                    clientId,
                    "Reusable blueprint",
                    IsAgent365Compatible: true,
                    Agent365CompatibilityIssue: null)
            ]);
        var handler = new ListAgentIdentityBlueprintsHandler(_catalog);

        var result = await handler.Handle(
            new ListAgentIdentityBlueprintsQuery(),
            CancellationToken.None);

        result.Items.Should().ContainSingle().Which.Should().BeEquivalentTo(new
        {
            BlueprintObjectId = objectId,
            BlueprintClientId = clientId,
            DisplayName = "Reusable blueprint",
            IsAgent365Compatible = true,
            Agent365CompatibilityIssue = (string?)null
        });
    }

    [Theory]
    [InlineData("MICROSOFT_GRAPH_RESPONSE_INVALID")]
    [InlineData("MICROSOFT_GRAPH_NEXT_LINK_INVALID")]
    public async Task Handle_Should_MapInvalidGraphCatalogResponseToSafeGatewayError(
        string dependencyCode)
    {
        _catalog.ListAsync(Arg.Any<CancellationToken>())
            .Returns<Task<IReadOnlyList<AgentIdentityBlueprintCatalogItem>>>(_ =>
                throw new Agent365ProvisioningException(
                    dependencyCode,
                    "Safe dependency summary"));
        var handler = new ListAgentIdentityBlueprintsHandler(_catalog);

        var action = () => handler.Handle(
            new ListAgentIdentityBlueprintsQuery(),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<DomainException>();
        exception.Which.ErrorCode.Should().Be(
            ErrorCodes.AGENT_IDENTITY_BLUEPRINT_CATALOG_INVALID_RESPONSE);
        exception.Which.Message.Should().NotContain("Safe dependency summary");
    }

    [Theory]
    [InlineData("MICROSOFT_GRAPH_FORBIDDEN")]
    [InlineData("MICROSOFT_GRAPH_THROTTLED")]
    [InlineData("PROVISIONING_CREDENTIAL_UNAVAILABLE")]
    public async Task Handle_Should_MapGraphAvailabilityFailureToSafeGatewayError(
        string dependencyCode)
    {
        _catalog.ListAsync(Arg.Any<CancellationToken>())
            .Returns<Task<IReadOnlyList<AgentIdentityBlueprintCatalogItem>>>(_ =>
                throw new Agent365ProvisioningException(
                    dependencyCode,
                    "Safe dependency summary",
                    isTransient: true));
        var handler = new ListAgentIdentityBlueprintsHandler(_catalog);

        var action = () => handler.Handle(
            new ListAgentIdentityBlueprintsQuery(),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<DomainException>();
        exception.Which.ErrorCode.Should().Be(
            ErrorCodes.AGENT_IDENTITY_BLUEPRINT_CATALOG_UNAVAILABLE);
        exception.Which.Message.Should().NotContain("Safe dependency summary");
    }
}
