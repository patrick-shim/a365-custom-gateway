using System.Net;
using System.Text.Json.Nodes;
using Gateway.TestSupport;

namespace Gateway.UnitTests;

public sealed class SampleGateTests
{
    [Theory]
    [InlineData("Disabled", "PurviewDisabled")]
    [InlineData("Allowed", "PurviewDisabled")]
    [InlineData("Allowed", "Allowed")]
    [InlineData("Allowed", "AuditOnly")]
    [InlineData("Allowed", "AuditLogged")]
    [InlineData("Allowed", "SimulatedBlock")]
    [InlineData("Allowed", "SimulationUnavailable")]
    public async Task Full_gate_evaluates_once_generates_once_and_submits_exact_bound_payload(
        string shield, string purview)
    {
        using var fixture = new SampleGateFixture();
        fixture.ExpectEvaluation(body =>
        {
            body["promptShieldProcessing"] = shield;
            body["purviewProcessing"] = purview;
        });
        fixture.ExpectActivity();
        fixture.ExpectInteraction(body => body["purviewProcessing"] = purview);

        Assert.Equal(0, await fixture.RunAsync());

        fixture.AssertCalls(evaluations: 1, activities: 1, models: 1, interactions: 1);
        fixture.AssertMatchingSubmission();
        Assert.Equal(["prompts:evaluate", "agent-activities", "model", "ai-interactions"], fixture.Sequence);
        Assert.Equal(fixture.Options.Message, Assert.Single(fixture.ModelPrompts));
        Assert.Contains($"Prompt Shields={shield}; Purview={purview}", fixture.Output.ToString());
        Assert.Contains("status=Accepted", fixture.Output.ToString());
        Assert.Contains("observability=Queued", fixture.Output.ToString());
        Assert.Contains("HTTP 202 does not prove completed processing or destination-specific downstream delivery",
            fixture.Output.ToString());
        if (purview == "SimulationUnavailable")
            Assert.Contains("not disabled or proven protective", fixture.Error.ToString());
        else
            Assert.Equal(string.Empty, fixture.Error.ToString());
    }

    [Theory]
    [InlineData("denied")]
    [InlineData("allowed-missing")]
    [InlineData("allowed-string")]
    [InlineData("decision-missing")]
    [InlineData("decision-blocked")]
    [InlineData("decision-stale")]
    [InlineData("decision-unavailable")]
    [InlineData("receipt-missing")]
    [InlineData("receipt-null")]
    [InlineData("receipt-empty")]
    [InlineData("receipt-malformed")]
    [InlineData("evaluation-missing")]
    [InlineData("evaluation-empty")]
    [InlineData("evaluation-mismatch")]
    [InlineData("interaction-missing")]
    [InlineData("interaction-mismatch")]
    [InlineData("shield-missing")]
    [InlineData("shield-blocked")]
    [InlineData("shield-unavailable")]
    [InlineData("purview-missing")]
    [InlineData("purview-blocked")]
    [InlineData("purview-unavailable")]
    [InlineData("purview-invalid-user")]
    [InlineData("deadline-missing")]
    [InlineData("deadline-null")]
    [InlineData("deadline-number")]
    [InlineData("deadline-malformed")]
    [InlineData("deadline-no-zone")]
    [InlineData("deadline-expired")]
    [InlineData("deadline-equality")]
    [InlineData("status-failed")]
    [InlineData("error-code")]
    [InlineData("error")]
    [InlineData("errors")]
    public async Task Denied_inconsistent_or_unavailable_proof_never_starts_generation(string mutation)
    {
        using var fixture = new SampleGateFixture();
        fixture.ExpectEvaluation(body => MutateEvaluation(body, mutation));

        Assert.Equal(4, await fixture.RunAsync());

        fixture.AssertCalls(evaluations: 1, activities: 0, models: 0, interactions: 0);
        Assert.DoesNotContain("[ALLOWED]", fixture.Output.ToString());
        Assert.Contains("No model call was made", fixture.Error.ToString());
    }

    [Theory]
    [InlineData("null")]
    [InlineData("[]")]
    [InlineData("{}")]
    [InlineData("not-json")]
    [InlineData("{\"allowed\": true")]
    public async Task Malformed_evaluation_does_not_authorize_the_callback(string body)
    {
        using var fixture = new SampleGateFixture();
        fixture.Expect(SampleGateFixture.EvaluationPath, _ => SampleGateFixture.RawResponse(body));

        Assert.Equal(4, await fixture.RunAsync());

        fixture.AssertCalls(1, 0, 0, 0);
        Assert.Contains("No model call was made", fixture.Error.ToString());
    }

    [Theory]
    [InlineData("allowed")]
    [InlineData("Allowed")]
    [InlineData("evaluationReceiptId")]
    public async Task Ambiguous_duplicate_evaluation_fields_fail_closed(string duplicate)
    {
        using var fixture = new SampleGateFixture();
        fixture.Expect(SampleGateFixture.EvaluationPath, request =>
        {
            var body = fixture.EvaluationBody(request).ToJsonString();
            var value = duplicate == "evaluationReceiptId" ? $"\"{fixture.ProofId:D}\"" : "true";
            return SampleGateFixture.RawResponse(body[..^1] + $",\"{duplicate}\":{value}}}");
        });

        Assert.Equal(4, await fixture.RunAsync());

        fixture.AssertCalls(1, 0, 0, 0);
        Assert.Contains("No model call was made", fixture.Error.ToString());
    }

    [Theory]
    [InlineData(HttpStatusCode.Accepted)]
    [InlineData(HttpStatusCode.NoContent)]
    [InlineData(HttpStatusCode.BadRequest)]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.Forbidden)]
    [InlineData(HttpStatusCode.Conflict)]
    [InlineData(HttpStatusCode.TooManyRequests)]
    [InlineData(HttpStatusCode.InternalServerError)]
    [InlineData(HttpStatusCode.ServiceUnavailable)]
    [InlineData(HttpStatusCode.TemporaryRedirect)]
    public async Task Non_ok_evaluation_does_not_follow_redirects_or_retry_even_with_an_allowed_body(HttpStatusCode status)
    {
        using var fixture = new SampleGateFixture();
        fixture.Expect(SampleGateFixture.EvaluationPath, request =>
        {
            var response = SampleGateFixture.JsonResponse(fixture.EvaluationBody(request), status);
            response.Headers.Location = new Uri("https://forbidden-fixture.invalid/");
            return response;
        });

        Assert.Equal(status == HttpStatusCode.Forbidden ? 3 : 4, await fixture.RunAsync());

        fixture.AssertCalls(1, 0, 0, 0);
        Assert.Contains($"HTTP {(int)status}", fixture.Error.ToString());
        Assert.Contains("No model call was made", fixture.Error.ToString());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Lost_evaluation_or_timeout_does_not_attempt_a_replacement_proof(bool timeout)
    {
        using var fixture = new SampleGateFixture();
        fixture.Expect(SampleGateFixture.EvaluationPath, _ =>
        {
            if (timeout)
                throw new TaskCanceledException(SampleGateFixture.PrivateDetail);
            throw new HttpRequestException(SampleGateFixture.PrivateDetail);
        });

        Assert.Equal(4, await fixture.RunAsync());

        fixture.AssertCalls(1, 0, 0, 0);
        Assert.Contains("No model call was made", fixture.Error.ToString());
    }

    [Theory]
    [InlineData(-1, 0, 1)]
    [InlineData(0, 4, 0)]
    [InlineData(1, 4, 0)]
    public async Task Expiry_is_rechecked_immediately_before_callback_and_equality_is_expired(
        int ticksAfterExpiry, int expectedExit, int expectedModels)
    {
        using var fixture = new SampleGateFixture();
        fixture.ExpectEvaluation();
        fixture.ExpectActivity(beforeResponse: () => fixture.Clock.Now = fixture.Deadline.AddTicks(ticksAfterExpiry));
        if (expectedModels == 1)
            fixture.ExpectInteraction();

        Assert.Equal(expectedExit, await fixture.RunAsync());

        fixture.AssertCalls(1, 1, expectedModels, expectedModels);
        if (expectedModels == 0)
            Assert.Contains("expired before generation", fixture.Error.ToString());
        else
            fixture.AssertMatchingSubmission();
    }

    [Theory]
    [InlineData(-8)]
    [InlineData(0)]
    [InlineData(9)]
    public async Task Explicit_offset_deadlines_are_compared_as_instants_not_local_time(int hours)
    {
        using var fixture = new SampleGateFixture();
        fixture.ExpectEvaluation(body => body["expiresAtUtc"] =
            fixture.Clock.Now.ToOffset(TimeSpan.FromHours(hours)).ToString("O"));

        Assert.Equal(4, await fixture.RunAsync());

        fixture.AssertCalls(1, 0, 0, 0);
        Assert.Contains("expired receipt deadline", fixture.Error.ToString());
    }

    [Fact]
    public async Task Cancellation_after_activity_does_not_start_generation()
    {
        using var fixture = new SampleGateFixture();
        using var cancelled = new CancellationTokenSource();
        fixture.ExpectEvaluation();
        fixture.ExpectActivity(beforeResponse: cancelled.Cancel);

        Assert.Equal(4, await fixture.RunAsync(cancellationToken: cancelled.Token));

        fixture.AssertCalls(1, 1, 0, 0);
        Assert.Contains("No model call was made", fixture.Error.ToString());
    }

    [Fact]
    public async Task Model_exception_is_not_a_reason_to_evaluate_or_invoke_again()
    {
        using var fixture = new SampleGateFixture();
        fixture.ExpectEvaluation();
        fixture.ExpectActivity();

        Assert.Equal(4, await fixture.RunAsync((_, _) => throw new InvalidOperationException(SampleGateFixture.PrivateDetail)));

        fixture.AssertCalls(1, 1, 1, 0);
        Assert.Contains("Do not repeat either blindly", fixture.Error.ToString());
        Assert.DoesNotContain("No model call was made", fixture.Error.ToString());
    }

    [Fact]
    public async Task Cancellation_inside_model_does_not_submit_or_rerun_it()
    {
        using var fixture = new SampleGateFixture();
        using var cancelled = new CancellationTokenSource();
        fixture.ExpectEvaluation();
        fixture.ExpectActivity();

        Assert.Equal(4, await fixture.RunAsync((_, _) =>
        {
            cancelled.Cancel();
            return Task.FromResult(SampleGateFixture.GeneratedResponse);
        }, cancelled.Token));

        fixture.AssertCalls(1, 1, 1, 0);
        Assert.Contains("Do not repeat either blindly", fixture.Error.ToString());
    }

    private static void MutateEvaluation(JsonObject body, string mutation)
    {
        switch (mutation)
        {
            case "denied": body["allowed"] = false; break;
            case "allowed-missing": body.Remove("allowed"); break;
            case "allowed-string": body["allowed"] = "true"; break;
            case "decision-missing": body.Remove("decision"); break;
            case "decision-blocked": body["decision"] = "PROMPT_BLOCKED_BY_DLP"; break;
            case "decision-stale": body["decision"] = "PROMPT_EVALUATION_INVALID"; break;
            case "decision-unavailable": body["decision"] = "PROMPT_EVALUATION_UNAVAILABLE"; break;
            case "receipt-missing": body.Remove("evaluationReceiptId"); break;
            case "receipt-null": body["evaluationReceiptId"] = null; break;
            case "receipt-empty": body["evaluationReceiptId"] = Guid.Empty; break;
            case "receipt-malformed": body["evaluationReceiptId"] = SampleGateFixture.PrivateDetail; break;
            case "evaluation-missing": body.Remove("evaluationId"); break;
            case "evaluation-empty": body["evaluationId"] = Guid.Empty; break;
            case "evaluation-mismatch": body["evaluationId"] = Guid.NewGuid(); break;
            case "interaction-missing": body.Remove("interactionId"); break;
            case "interaction-mismatch": body["interactionId"] = "another-interaction"; break;
            case "shield-missing": body.Remove("promptShieldProcessing"); break;
            case "shield-blocked": body["promptShieldProcessing"] = "Blocked"; break;
            case "shield-unavailable": body["promptShieldProcessing"] = SampleGateFixture.PrivateDetail; break;
            case "purview-missing": body.Remove("purviewProcessing"); break;
            case "purview-blocked": body["purviewProcessing"] = "Blocked"; break;
            case "purview-unavailable": body["purviewProcessing"] = SampleGateFixture.PrivateDetail; break;
            case "purview-invalid-user": body["purviewProcessing"] = "PurviewSkipped_InvalidUser"; break;
            case "deadline-missing": body.Remove("expiresAtUtc"); break;
            case "deadline-null": body["expiresAtUtc"] = null; break;
            case "deadline-number": body["expiresAtUtc"] = 123; break;
            case "deadline-malformed": body["expiresAtUtc"] = "2030-99-99T00:00:00Z"; break;
            case "deadline-no-zone": body["expiresAtUtc"] = TestData.Now.AddMinutes(5).ToString("s"); break;
            case "deadline-expired": body["expiresAtUtc"] = TestData.Now.AddTicks(-1).ToString("O"); break;
            case "deadline-equality": body["expiresAtUtc"] = TestData.Now.ToString("O"); break;
            case "status-failed": body["status"] = "Failed"; break;
            case "error-code": body["errorCode"] = "PROMPT_EVALUATION_INVALID"; break;
            case "error": body["error"] = SampleGateFixture.PrivateDetail; break;
            case "errors": body["errors"] = new JsonArray(SampleGateFixture.PrivateDetail); break;
            default: throw new ArgumentOutOfRangeException(nameof(mutation));
        }
    }
}
