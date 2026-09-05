using System.Text.Json;
using FluentAssertions;
using Gateway.AdminUi.Models;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;

namespace Gateway.AdminUi.Tests.Models;

public sealed class ProtectionOperationTicketTests
{
    [Fact]
    public void ReviewTicket_KeepsOpaqueValuePrivateAndConsumesItOnce()
    {
        const string opaqueReviewValue = "opaque-review-value";
        var reviewTokenId = Guid.NewGuid();
        var ticket = new ProtectionOperationReviewTicket(
            new ProtectionOperationReviewResponse(
                reviewTokenId,
                opaqueReviewValue,
                "reviewed-payload-hash",
                DateTime.UtcNow.AddMinutes(5),
                CreateReview()),
            "row-version");

        ticket.IsAvailable.Should().BeTrue();
        ticket.ToString().Should().NotContain(opaqueReviewValue);
        JsonSerializer.Serialize(ticket).Should().NotContain(opaqueReviewValue);
        typeof(ProtectionOperationReviewTicket)
            .GetProperties()
            .Should().NotContain(property => property.Name == "ReviewToken");

        var request = ticket.Consume();

        request.ReviewTokenId.Should().Be(reviewTokenId);
        request.ReviewToken.Should().Be(opaqueReviewValue);
        ticket.IsAvailable.Should().BeFalse();
        var secondUse = ticket.Invoking(value => value.Consume());
        secondUse.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void ConfirmationTicket_KeepsOpaqueValuePrivateAndConsumesItOnce()
    {
        const string opaqueConfirmationValue = "opaque-confirmation-value";
        var ticket = new ProtectionOperationConfirmationTicket(
            new ProtectionOperationConfirmationResponse(
                Guid.NewGuid(),
                Guid.NewGuid(),
                opaqueConfirmationValue,
                DateTime.UtcNow.AddMinutes(5)),
            CreateReview(),
            "row-version");

        ticket.IsAvailable.Should().BeTrue();
        ticket.ToString().Should().NotContain(opaqueConfirmationValue);
        JsonSerializer.Serialize(ticket).Should().NotContain(opaqueConfirmationValue);
        typeof(ProtectionOperationConfirmationTicket)
            .GetProperties()
            .Should().NotContain(property => property.Name == "ConfirmationToken");

        ticket.Consume().Should().Be(opaqueConfirmationValue);

        ticket.IsAvailable.Should().BeFalse();
        var secondUse = ticket.Invoking(value => value.Consume());
        secondUse.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void ReviewTicket_DefensivelyCopiesReviewedCollections()
    {
        var activities = new List<string> { "uploadText" };
        var actions = new List<PurviewDlpRuleActionDto>
        {
            new("uploadText", "block")
        };
        var review = CreateReview() with
        {
            Activities = activities,
            Actions = actions
        };
        var ticket = new ProtectionOperationReviewTicket(
            new ProtectionOperationReviewResponse(
                Guid.NewGuid(),
                "opaque-review-value",
                "reviewed-payload-hash",
                DateTime.UtcNow.AddMinutes(5),
                review),
            "row-version");

        activities[0] = "downloadText";
        actions.Clear();

        ticket.Review.Activities.Should().Equal("uploadText");
        ticket.Review.Actions.Should().ContainSingle(action =>
            action.Activity == "uploadText" && action.Action == "block");
    }

    private static ProtectionOperationReviewSummaryDto CreateReview() =>
        new(
            Guid.NewGuid(),
            "UpdateDlpProfile",
            "PurviewDlpProfile",
            Guid.NewGuid().ToString("D"),
            Guid.NewGuid(),
            Guid.NewGuid(),
            "Sensitive information",
            "Enforce",
            ["uploadText"],
            [new PurviewDlpRuleActionDto("uploadText", "block")],
            "Individual",
            "Application",
            "Readback is not propagation or runtime-verdict proof.");
}
