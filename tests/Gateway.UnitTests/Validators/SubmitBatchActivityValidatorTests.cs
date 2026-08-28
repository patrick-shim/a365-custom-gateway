using FluentAssertions;
using Gateway.Application.Activities.Commands;
using Gateway.Application.Activities.Validators;
using Gateway.Contracts.Dtos;

namespace Gateway.UnitTests.Validators;

public class SubmitBatchActivityValidatorTests
{
    private readonly SubmitBatchActivityValidator _validator = new();

    [Fact]
    public void Validate_ShouldAcceptStructurallyValidBatch()
    {
        _validator.Validate(CreateCommand()).IsValid.Should().BeTrue();
    }

    [Fact]
    public void Validate_ShouldRejectEmptyBatch()
    {
        var result = _validator.Validate(CreateCommand() with { Activities = [] });

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(error => error.PropertyName == "Activities");
    }

    [Fact]
    public void Validate_ShouldRejectMoreThanOneHundredItems()
    {
        var result = _validator.Validate(CreateCommand() with
        {
            Activities = Enumerable.Range(1, 101)
                .Select(index => CreateItem($"activity-{index}"))
                .ToList()
        });

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(error => error.PropertyName == "Activities");
    }

    [Theory]
    [InlineData("")]
    [InlineData("not-an-activity-type")]
    public void Validate_ShouldRejectMalformedItemActivityType(string activityType)
    {
        var result = _validator.Validate(CreateCommand() with
        {
            Activities = [CreateItem("activity-001") with { ActivityType = activityType }]
        });

        result.IsValid.Should().BeFalse();
        result.Errors.Should().Contain(error =>
            error.PropertyName == "Activities[0].ActivityType");
    }

    [Fact]
    public void Validate_ShouldRejectNullAttributeValueWithoutThrowing()
    {
        var attributes = new Dictionary<string, string>
        {
            ["unsafe-null"] = null!
        };
        var command = CreateCommand() with
        {
            Activities = [CreateItem("activity-001") with { Attributes = attributes }]
        };

        var action = () => _validator.Validate(command);

        action.Should().NotThrow();
        action().IsValid.Should().BeFalse();
    }

    private static SubmitBatchActivityCommand CreateCommand() =>
        new(
            "agent-001",
            [CreateItem("activity-001")],
            Guid.NewGuid(),
            Guid.NewGuid().ToString("D"));

    private static BatchActivityItemDto CreateItem(string activityId) =>
        new(
            activityId,
            "session-001",
            "Chat",
            DateTime.UtcNow.AddMinutes(-1),
            new ActorDto("User", Guid.NewGuid().ToString("D")),
            null,
            null);
}
