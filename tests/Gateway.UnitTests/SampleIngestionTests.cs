using System.Net;
using System.Text.Json.Nodes;

namespace Gateway.UnitTests;

public sealed class SampleIngestionTests
{
    public static IEnumerable<object[]> InvalidReceipts()
    {
        foreach (var interaction in new[] { false, true })
        foreach (var mutation in new[]
        {
            "null", "array", "empty", "invalid-json", "receipt-missing", "receipt-empty", "receipt-malformed",
            "binding-missing", "binding-wrong", "status-missing", "status-null", "status-failed", "status-unknown",
            "status-number", "duplicate-status", "error-code", "error", "errors"
        })
            yield return [interaction, mutation];
        yield return [false, "received-at-missing"];
        yield return [false, "received-at-malformed"];
        foreach (var mutation in new[]
        {
            "purview-missing", "purview-blocked", "purview-unknown", "purview-invalid-user", "observability-missing",
            "observability-failed", "observability-unknown", "observability-unsupported", "observability-no-user"
        })
            yield return [true, mutation];
    }

    [Theory]
    [MemberData(nameof(InvalidReceipts))]
    public async Task Http_202_with_failed_or_malformed_body_is_not_success_and_never_causes_retry(
        bool interaction, string mutation)
    {
        using var fixture = new SampleGateFixture();
        fixture.ExpectEvaluation();
        if (interaction)
            fixture.ExpectActivity();
        fixture.Expect(interaction ? SampleGateFixture.InteractionPath : SampleGateFixture.ActivityPath, request =>
            InvalidReceipt(interaction
                ? SampleGateFixture.InteractionBody(request)
                : fixture.ActivityBody(request), interaction, mutation));

        Assert.Equal(4, await fixture.RunAsync());

        fixture.AssertCalls(1, 1, interaction ? 1 : 0, interaction ? 1 : 0);
        Assert.DoesNotContain("[PASS]", fixture.Output.ToString());
        Assert.DoesNotContain("returned matching receipts", fixture.Output.ToString());
        Assert.Contains("HTTP 202", fixture.Error.ToString());
        Assert.DoesNotContain($"[ACCEPTED] {(interaction ? "message" : "activity/OTel")} ingestion", fixture.Output.ToString());
        if (mutation == "status-failed")
            Assert.Contains("status=Failed", fixture.Error.ToString());
        if (interaction)
        {
            fixture.AssertMatchingSubmission();
            Assert.Contains("Generation already completed", fixture.Error.ToString());
            Assert.Contains("Do not repeat the model call or ingestion blindly", fixture.Error.ToString());
        }
    }

    public static IEnumerable<object[]> RejectedIngestions() =>
        from interaction in new[] { false, true }
        from status in new[]
        {
            HttpStatusCode.OK, HttpStatusCode.Forbidden, HttpStatusCode.Conflict,
            HttpStatusCode.TooManyRequests, HttpStatusCode.InternalServerError, HttpStatusCode.ServiceUnavailable
        }
        select new object[] { interaction, status };

    [Theory]
    [MemberData(nameof(RejectedIngestions))]
    public async Task Server_rejection_or_unavailability_does_not_retry_or_mint_replacement_proof(
        bool interaction, HttpStatusCode status)
    {
        using var fixture = new SampleGateFixture();
        fixture.ExpectEvaluation();
        if (interaction)
            fixture.ExpectActivity();
        fixture.Expect(interaction ? SampleGateFixture.InteractionPath : SampleGateFixture.ActivityPath,
            _ => SampleGateFixture.RawResponse(SampleGateFixture.PrivateDetail, status));

        Assert.Equal(4, await fixture.RunAsync());

        fixture.AssertCalls(1, 1, interaction ? 1 : 0, interaction ? 1 : 0);
        Assert.Contains($"HTTP {(int)status}", fixture.Error.ToString());
        Assert.DoesNotContain("returned matching receipts", fixture.Output.ToString());
        if (interaction)
        {
            fixture.AssertMatchingSubmission();
            Assert.Contains("Do not repeat the model call or ingestion blindly", fixture.Error.ToString());
        }
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(false, true)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public async Task Unknown_ingestion_outcome_is_not_replayed_after_transport_failure(bool interaction, bool timeout)
    {
        using var fixture = new SampleGateFixture();
        fixture.ExpectEvaluation();
        if (interaction)
            fixture.ExpectActivity();
        fixture.Expect(interaction ? SampleGateFixture.InteractionPath : SampleGateFixture.ActivityPath,
            _ =>
            {
                if (timeout)
                    throw new TaskCanceledException(SampleGateFixture.PrivateDetail);
                throw new HttpRequestException(SampleGateFixture.PrivateDetail);
            });

        Assert.Equal(4, await fixture.RunAsync());

        fixture.AssertCalls(1, 1, interaction ? 1 : 0, interaction ? 1 : 0);
        Assert.DoesNotContain("returned matching receipts", fixture.Output.ToString());
        Assert.Contains(interaction ? "Do not repeat either blindly" : "No model call was made", fixture.Error.ToString());
        if (interaction)
            fixture.AssertMatchingSubmission();
    }

    [Theory]
    [InlineData("Accepted", "Pending")]
    [InlineData("Accepted", "Queued")]
    [InlineData("Processing", "Processing")]
    [InlineData("Processed", "Completed")]
    [InlineData("Processed", "Disabled")]
    public async Task Receipt_status_is_reported_without_promising_destination_delivery(string status, string observability)
    {
        using var fixture = new SampleGateFixture();
        fixture.ExpectEvaluation(body => body["correlationId"] = SampleGateFixture.PrivateDetail);
        fixture.ExpectActivity(body =>
        {
            body["status"] = status;
            body["correlationId"] = SampleGateFixture.PrivateDetail;
        });
        fixture.ExpectInteraction(body =>
        {
            body["status"] = status;
            body["observabilityProcessing"] = observability;
            body["correlationId"] = SampleGateFixture.PrivateDetail;
            body["errorCode"] = null;
            body["error"] = null;
            body["errors"] = null;
        });

        Assert.Equal(0, await fixture.RunAsync());

        fixture.AssertCalls(1, 1, 1, 1);
        fixture.AssertMatchingSubmission();
        Assert.Contains($"status={status}", fixture.Output.ToString());
        Assert.Contains($"observability={observability}", fixture.Output.ToString());
        Assert.Contains("correlation unavailable", fixture.Output.ToString());
        Assert.Contains("Downstream delivery is not proven", fixture.Output.ToString());
        Assert.Equal(string.Empty, fixture.Error.ToString());
    }

    private static HttpResponseMessage InvalidReceipt(JsonObject body, bool interaction, string mutation)
    {
        switch (mutation)
        {
            case "null": return SampleGateFixture.RawResponse("null", HttpStatusCode.Accepted);
            case "array": return SampleGateFixture.RawResponse("[]", HttpStatusCode.Accepted);
            case "empty": return SampleGateFixture.RawResponse("{}", HttpStatusCode.Accepted);
            case "invalid-json": return SampleGateFixture.RawResponse("{", HttpStatusCode.Accepted);
            case "receipt-missing": body.Remove("receiptId"); break;
            case "receipt-empty": body["receiptId"] = Guid.Empty; break;
            case "receipt-malformed": body["receiptId"] = SampleGateFixture.PrivateDetail; break;
            case "binding-missing": body.Remove(interaction ? "interactionId" : "activityId"); break;
            case "binding-wrong": body[interaction ? "interactionId" : "activityId"] = "another-id"; break;
            case "status-missing": body.Remove("status"); break;
            case "status-null": body["status"] = null; break;
            case "status-failed": body["status"] = "Failed"; break;
            case "status-unknown": body["status"] = SampleGateFixture.PrivateDetail; break;
            case "status-number": body["status"] = 202; break;
            case "duplicate-status":
                return SampleGateFixture.RawResponse(body.ToJsonString()[..^1] + ",\"Status\":\"Failed\"}", HttpStatusCode.Accepted);
            case "error-code": body["errorCode"] = SampleGateFixture.PrivateDetail; break;
            case "error": body["error"] = new JsonObject { ["detail"] = SampleGateFixture.PrivateDetail }; break;
            case "errors": body["errors"] = new JsonArray(SampleGateFixture.PrivateDetail); break;
            case "received-at-missing": body.Remove("receivedAtUtc"); break;
            case "received-at-malformed": body["receivedAtUtc"] = "2030-01-02T03:04:05"; break;
            case "purview-missing": body.Remove("purviewProcessing"); break;
            case "purview-blocked": body["purviewProcessing"] = "Blocked"; break;
            case "purview-unknown": body["purviewProcessing"] = SampleGateFixture.PrivateDetail; break;
            case "purview-invalid-user": body["purviewProcessing"] = "PurviewSkipped_InvalidUser"; break;
            case "observability-missing": body.Remove("observabilityProcessing"); break;
            case "observability-failed": body["observabilityProcessing"] = "Failed"; break;
            case "observability-unknown": body["observabilityProcessing"] = SampleGateFixture.PrivateDetail; break;
            case "observability-unsupported": body["observabilityProcessing"] = "UnsupportedActivity"; break;
            case "observability-no-user": body["observabilityProcessing"] = "MissingUserContext"; break;
            default: throw new ArgumentOutOfRangeException(nameof(mutation));
        }
        return SampleGateFixture.JsonResponse(body);
    }
}
