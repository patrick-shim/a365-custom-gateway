using FluentAssertions;
using Gateway.Application.Activities.Commands;
using Gateway.Application.Activities.Validators;
using Gateway.Contracts.Dtos;

namespace Gateway.UnitTests.Validators;

public class SubmitActivityValidatorTests
{
    private readonly SubmitActivityValidator _validator = new();

    private static SubmitActivityCommand CreateValidCommand() =>
        new(
            ExternalAgentId: "agent-001",
            ActivityId: "activity-001",
            SessionId: "session-001",
            ActivityType: "ToolInvocation",
            OccurredAtUtc: DateTime.UtcNow.AddMinutes(-5),
            Actor: new ActorDto("Agent"),
            Tool: null,
            Attributes: null,
            CallerClientId: "client-001",
            IdempotencyKey: null);

    [Fact]
    public void Validate_Should_Pass_When_CommandIsValid()
    {
        var command = CreateValidCommand();

        var result = _validator.Validate(command);

        result.IsValid.Should().BeTrue();
    }

    [Fact]
    public void Validate_Should_Pass_When_ToolIsProvided_With_ValidData()
    {
        var command = CreateValidCommand() with
        {
            Tool = new ToolDto("my-tool", "search", "Succeeded", 150)
        };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeTrue();
    }

    [Fact]
    public void Validate_Should_Fail_When_ExternalAgentIdIsEmpty()
    {
        var command = CreateValidCommand() with { ExternalAgentId = "" };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "ExternalAgentId");
    }

    [Fact]
    public void Validate_Should_Fail_When_ActivityIdIsEmpty()
    {
        var command = CreateValidCommand() with { ActivityId = "" };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "ActivityId");
    }

    [Fact]
    public void Validate_Should_Fail_When_ActivityIdExceeds256Chars()
    {
        var command = CreateValidCommand() with { ActivityId = new string('x', 257) };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "ActivityId");
    }

    [Fact]
    public void Validate_Should_Fail_When_ActivityTypeIsInvalid()
    {
        var command = CreateValidCommand() with { ActivityType = "InvalidType" };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "ActivityType");
    }

    [Theory]
    [InlineData("ToolInvocation")]
    [InlineData("Chat")]
    [InlineData("InvokeAgent")]
    [InlineData("OutputMessages")]
    [InlineData("Custom")]
    public void Validate_Should_Pass_When_ActivityTypeIsValid(string activityType)
    {
        var command = CreateValidCommand() with { ActivityType = activityType };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeTrue();
    }

    [Fact]
    public void Validate_Should_Fail_When_ActorIsNull()
    {
        var command = CreateValidCommand() with { Actor = null! };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "Actor");
    }

    [Fact]
    public void Validate_Should_Fail_When_ActorTypeIsInvalid()
    {
        var command = CreateValidCommand() with { Actor = new ActorDto("InvalidActor") };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "Actor.Type");
    }

    [Theory]
    [InlineData("Agent")]
    [InlineData("User")]
    [InlineData("System")]
    public void Validate_Should_Pass_When_ActorTypeIsValid(string actorType)
    {
        var command = CreateValidCommand() with { Actor = new ActorDto(actorType) };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeTrue();
    }

    [Fact]
    public void Validate_Should_Fail_When_OccurredAtUtcIsInFuture()
    {
        var command = CreateValidCommand() with
        {
            OccurredAtUtc = DateTime.UtcNow.AddHours(1)
        };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "OccurredAtUtc");
    }

    [Fact]
    public void Validate_Should_Fail_When_ToolNameIsEmpty()
    {
        var command = CreateValidCommand() with
        {
            Tool = new ToolDto("", "operation", "Succeeded", 100)
        };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "Tool.Name");
    }

    [Fact]
    public void Validate_Should_Fail_When_ToolOutcomeIsInvalid()
    {
        var command = CreateValidCommand() with
        {
            Tool = new ToolDto("my-tool", "operation", "InvalidOutcome", 100)
        };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(e => e.PropertyName == "Tool.Outcome");
    }

    [Theory]
    [InlineData("Succeeded")]
    [InlineData("Failed")]
    [InlineData("Cancelled")]
    public void Validate_Should_Pass_When_ToolOutcomeIsValid(string outcome)
    {
        var command = CreateValidCommand() with
        {
            Tool = new ToolDto("my-tool", "operation", outcome, 100)
        };

        var result = _validator.Validate(command);

        result.IsValid.Should().BeTrue();
    }
}
