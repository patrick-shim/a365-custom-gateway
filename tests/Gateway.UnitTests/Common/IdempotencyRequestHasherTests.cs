using FluentAssertions;
using Gateway.Application.Activities.Commands;
using Gateway.Application.Common;
using Gateway.Application.Interactions.Commands;
using Gateway.Contracts.Dtos;

namespace Gateway.UnitTests.Common;

public class IdempotencyRequestHasherTests
{
    private static readonly Guid RegistrationId =
        Guid.Parse("e2a13812-f345-42ca-89f7-e8531179a29a");
    private static readonly DateTime OccurredAtUtc =
        new(2026, 8, 25, 1, 2, 3, DateTimeKind.Utc);

    [Fact]
    public void ComputeActivity_ShouldBeDeterministicAcrossDictionaryInsertionOrder()
    {
        var first = CreateActivity(new Dictionary<string, string>
        {
            ["zeta"] = "last",
            ["alpha"] = "first"
        });
        var second = CreateActivity(new Dictionary<string, string>
        {
            ["alpha"] = "first",
            ["zeta"] = "last"
        });

        IdempotencyRequestHasher.Compute(first)
            .Should().Be(IdempotencyRequestHasher.Compute(second));
    }

    [Fact]
    public void ComputeActivity_ShouldChangeWhenRequestPayloadChanges()
    {
        var first = CreateActivity(null);
        var second = first with { ActivityId = "activity-different" };

        IdempotencyRequestHasher.Compute(first)
            .Should().NotBe(IdempotencyRequestHasher.Compute(second));
    }

    [Fact]
    public void ComputeBatch_ShouldPreserveItemOrderAsPartOfCanonicalPayload()
    {
        var firstItem = CreateBatchItem("activity-one");
        var secondItem = CreateBatchItem("activity-two");
        var first = new SubmitBatchActivityCommand(
            "agent-001",
            [firstItem, secondItem],
            RegistrationId,
            "same-key");
        var second = first with { Activities = [secondItem, firstItem] };

        IdempotencyRequestHasher.Compute(first)
            .Should().NotBe(IdempotencyRequestHasher.Compute(second));
    }

    [Fact]
    public void ComputeInteraction_ShouldChangeWhenProtectedContentChanges()
    {
        var first = new SubmitInteractionCommand(
            "agent-001",
            "interaction-001",
            "session-001",
            OccurredAtUtc,
            null,
            new ContentDto("text/plain", "prompt one"),
            new ContentDto("text/plain", "response"),
            null,
            null,
            RegistrationId,
            "same-key");
        var second = first with
        {
            Prompt = new ContentDto("text/plain", "prompt two")
        };

        IdempotencyRequestHasher.Compute(first)
            .Should().NotBe(IdempotencyRequestHasher.Compute(second));
    }

    private static SubmitActivityCommand CreateActivity(
        Dictionary<string, string>? attributes) =>
        new(
            "agent-001",
            "activity-001",
            "session-001",
            "Chat",
            OccurredAtUtc,
            new ActorDto("User", Guid.Empty.ToString("D")),
            null,
            attributes,
            RegistrationId,
            "same-key");

    private static BatchActivityItemDto CreateBatchItem(string activityId) =>
        new(
            activityId,
            "session-001",
            "Chat",
            OccurredAtUtc,
            new ActorDto("User", Guid.Empty.ToString("D")),
            null,
            null);
}
