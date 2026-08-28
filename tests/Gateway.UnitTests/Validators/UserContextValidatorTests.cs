using FluentAssertions;
using Gateway.Application.Activities.Validators;
using Gateway.Application.Interactions.Commands;
using Gateway.Contracts.Dtos;

namespace Gateway.UnitTests.Validators;

public class UserContextValidatorTests
{
    [Theory]
    [InlineData("not-a-guid")]
    [InlineData("00000000-0000-0000-0000-000000000000")]
    public void SubmitInteractionValidator_Should_RejectInvalidTenantUserObjectId(string objectId)
    {
        var validator = new SubmitInteractionValidator();
        var command = new SubmitInteractionCommand(
            ExternalAgentId: "agent-001",
            InteractionId: "interaction-001",
            SessionId: null,
            OccurredAtUtc: DateTime.UtcNow.AddMinutes(-1),
            UserContext: new UserContextDto(objectId),
            Prompt: new ContentDto("text/plain", "prompt"),
            Response: new ContentDto("text/plain", "response"),
            Model: null,
            Metadata: null,
            CallerAgentRegistrationId: Guid.NewGuid(),
            IdempotencyKey: null);

        var result = validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(error =>
            error.PropertyName == "UserContext.TenantUserObjectId");
    }

    [Theory]
    [InlineData("application/json")]
    [InlineData("text/html")]
    [InlineData("")]
    public void SubmitInteractionValidator_ShouldRejectUnsupportedContentType(string contentType)
    {
        var validator = new SubmitInteractionValidator();
        var command = CreateValidCommand() with
        {
            Prompt = new ContentDto(contentType, "prompt")
        };

        var result = validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(error =>
            error.PropertyName == "Prompt.ContentType");
    }

    [Theory]
    [InlineData("text/plain")]
    [InlineData("text/markdown")]
    public void SubmitInteractionValidator_ShouldAcceptSupportedContentType(string contentType)
    {
        var validator = new SubmitInteractionValidator();
        var command = CreateValidCommand() with
        {
            Prompt = new ContentDto(contentType, "prompt"),
            Response = new ContentDto(contentType, "response")
        };

        validator.Validate(command).IsValid.Should().BeTrue();
    }

    [Fact]
    public void SubmitInteractionValidator_ShouldRejectContentOver32768Characters()
    {
        var validator = new SubmitInteractionValidator();
        var command = CreateValidCommand() with
        {
            Response = new ContentDto("text/plain", new string('x', 32_769))
        };

        var result = validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(error =>
            error.PropertyName == "Response.Content");
    }

    private static SubmitInteractionCommand CreateValidCommand() =>
        new(
            ExternalAgentId: "agent-001",
            InteractionId: "interaction-001",
            SessionId: null,
            OccurredAtUtc: DateTime.UtcNow.AddMinutes(-1),
            UserContext: null,
            Prompt: new ContentDto("text/plain", "prompt"),
            Response: new ContentDto("text/plain", "response"),
            Model: null,
            Metadata: null,
            CallerAgentRegistrationId: Guid.NewGuid(),
            IdempotencyKey: null);

}
