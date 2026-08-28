using System.Net;
using FluentAssertions;
using Gateway.AdminUi.Components.Shared;
using Gateway.AdminUi.Services;

namespace Gateway.AdminUi.Tests.Components;

public sealed class UiErrorInfoTests
{
    [Fact]
    public void FromException_UsesSafeProblemDetailAndCorrelationId()
    {
        var exception = new GatewayApiException(
            HttpStatusCode.Conflict,
            "State conflict",
            "Refresh the agent and try again.",
            "https://gateway.test/problems/conflict",
            "/api/v1/agents/id",
            "GW-CONFLICT",
            "correlation-123",
            new Dictionary<string, string[]>(),
            null);

        var result = UiErrorInfo.FromException(exception);

        result.Message.Should().Be("Refresh the agent and try again.");
        result.CorrelationId.Should().Be("correlation-123");
    }

    [Fact]
    public void FromException_FallsBackToProblemTitleWhenDetailIsMissing()
    {
        var exception = new GatewayApiException(
            HttpStatusCode.Forbidden,
            "You are not authorized to perform this action.",
            null,
            null,
            null,
            null,
            "correlation-456",
            new Dictionary<string, string[]>(),
            null);

        var result = UiErrorInfo.FromException(exception);

        result.Message.Should().Be("You are not authorized to perform this action.");
        result.CorrelationId.Should().Be("correlation-456");
    }

    [Fact]
    public void FromException_MapsClaimsChallengeToSafeActionableGuidance()
    {
        var exception = new GatewayApiException(
            HttpStatusCode.Unauthorized,
            "Additional Microsoft Entra authorization is required",
            "Safe API detail.",
            "https://gateway.example.com/problems/delegated-authorization-required",
            "/api/v1/operations/id:complete-agent365-registration",
            "AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED",
            "challenge-correlation",
            new Dictionary<string, string[]>(),
            null,
            requiresUserInteraction: true,
            hasClaimsChallenge: true,
            requiredScopes:
            [
                "https://graph.microsoft.com/AgentRegistration.ReadWrite.All"
            ]);

        var result = UiErrorInfo.FromException(exception);

        result.Message.Should().Contain("Conditional Access");
        result.Message.Should().Contain("Sign in again");
        result.RequiresUserInteraction.Should().BeTrue();
        result.HasClaimsChallenge.Should().BeTrue();
        result.RequiredScopes.Should().Equal(
            "https://graph.microsoft.com/AgentRegistration.ReadWrite.All");
        result.CorrelationId.Should().Be("challenge-correlation");
        result.Message.Should().NotContain("Safe API detail.");
    }

    [Fact]
    public void FromException_DoesNotExposeUnexpectedExceptionMessage()
    {
        var exception = new InvalidOperationException("sensitive implementation detail");

        var result = UiErrorInfo.FromException(exception);

        result.Message.Should().Be(
            "The gateway could not complete the request. Try again or contact support if the problem continues.");
        result.Message.Should().NotContain(exception.Message);
        result.CorrelationId.Should().BeNull();
    }

    [Fact]
    public void FromException_MapsCancellationWithoutTreatingItAsAnApiFailure()
    {
        var result = UiErrorInfo.FromException(new OperationCanceledException("internal"));

        result.Should().Be(new UiErrorInfo("The request was cancelled."));
    }
}
