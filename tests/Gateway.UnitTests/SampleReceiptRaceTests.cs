using System.Net;
using Gateway.Application.Prompts;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.TestSupport;

namespace Gateway.UnitTests;

public sealed class SampleReceiptRaceTests
{
    [Theory]
    [InlineData("expiry")]
    [InlineData("revision")]
    [InlineData("shared-policy")]
    [InlineData("shield-off")]
    [InlineData("registration-disabled")]
    [InlineData("child-identity")]
    [InlineData("consumed")]
    [InlineData("wrong-child")]
    [InlineData("wrong-receipt")]
    [InlineData("wrong-interaction")]
    [InlineData("wrong-user")]
    [InlineData("wrong-content")]
    [InlineData("wrong-content-type")]
    public async Task Model_time_expiry_or_server_binding_rejection_never_repeats_generation(string mutation)
    {
        using var fixture = new SampleGateFixture();
        var agent = TestData.Agent(promptShield: true, purview: true);
        var profile = TestData.ReadyProfile();
        agent.BlueprintId = profile.BlueprintApplicationId.Value.ToString("D");
        var snapshot = PromptProtectionContext.Capture(agent, profile);
        PromptEvaluationRecord? proof = null;
        var validationCalls = 0;
        var serverAccepted = false;

        fixture.Expect(SampleGateFixture.EvaluationPath, request =>
        {
            var digest = PromptReceiptSecurity.Create(
                request.Body.GetProperty("prompt").GetProperty("contentType").GetString()!,
                request.Body.GetProperty("prompt").GetProperty("content").GetString()!);
            proof = new PromptEvaluationRecord
            {
                Id = fixture.ProofId,
                AgentRegistrationId = agent.Id,
                ProtectionRevision = snapshot.ProtectionRevision,
                ProtectionContextHash = snapshot.Hash,
                PromptShieldRequired = snapshot.PromptShieldRequired,
                EvaluatedPurviewPolicyMode = snapshot.PurviewMode,
                Outcome = PromptEvaluationOutcome.Allowed,
                PromptShieldDecision = PromptShieldDecisionType.Allowed,
                PurviewDecision = PurviewDecisionType.Allowed,
                ExternalInteractionId = request.Body.GetProperty("interactionId").GetString()!,
                TenantUserObjectId = request.Body.GetProperty("userContext").GetProperty("tenantUserObjectId").GetString()!,
                PromptHashSalt = digest.Salt,
                PromptHash = digest.Hash,
                ExpiresAtUtc = fixture.Deadline.UtcDateTime
            };
            var body = fixture.EvaluationBody(request);
            body["purviewProcessing"] = "Allowed";
            return SampleGateFixture.JsonResponse(body, HttpStatusCode.OK);
        });
        fixture.ExpectActivity();
        fixture.Expect(SampleGateFixture.InteractionPath, request =>
        {
            validationCalls++;
            var received = request.Body;
            var currentContext = PromptProtectionContext.Capture(agent, profile);
            serverAccepted = proof is not null &&
                proof.Id == received.GetProperty("promptEvaluationReceiptId").GetGuid() &&
                currentContext.MatchesReceipt(proof, fixture.Clock.GetUtcNow().UtcDateTime) &&
                proof.ExternalInteractionId == received.GetProperty("interactionId").GetString() &&
                proof.TenantUserObjectId == received.GetProperty("userContext").GetProperty("tenantUserObjectId").GetString() &&
                PromptReceiptSecurity.Verify(proof.PromptHashSalt, proof.PromptHash,
                    received.GetProperty("prompt").GetProperty("contentType").GetString()!,
                    received.GetProperty("prompt").GetProperty("content").GetString()!);
            return serverAccepted
                ? SampleGateFixture.JsonResponse(SampleGateFixture.InteractionBody(request))
                : SampleGateFixture.Rejection("PROMPT_EVALUATION_INVALID");
        });

        var result = await fixture.RunAsync((_, _) =>
        {
            switch (mutation)
            {
                case "expiry": fixture.Clock.Now = fixture.Deadline; break;
                case "revision": agent.ProtectionRevision = Guid.NewGuid(); break;
                case "shared-policy": profile.PolicyMode = PurviewPolicyMode.SimulationWithTips; break;
                case "shield-off": agent.FeatureConfiguration.PromptShieldEnabled = false; break;
                case "registration-disabled": agent.Status = AgentStatus.Disabled; break;
                case "child-identity": agent.Agent365AgentId = Guid.NewGuid().ToString("D"); break;
                case "consumed": proof!.ConsumedAtUtc = TestData.Now; break;
                case "wrong-child": proof!.AgentRegistrationId = Guid.NewGuid(); break;
                case "wrong-receipt": proof!.Id = Guid.NewGuid(); break;
                case "wrong-interaction": proof!.ExternalInteractionId = "different-interaction"; break;
                case "wrong-user": proof!.TenantUserObjectId = Guid.NewGuid().ToString("D"); break;
                case "wrong-content":
                case "wrong-content-type":
                    var digest = PromptReceiptSecurity.Create(
                        mutation == "wrong-content-type" ? "text/markdown" : "text/plain",
                        mutation == "wrong-content" ? "different prompt" : fixture.Options.Message);
                    proof!.PromptHashSalt = digest.Salt;
                    proof.PromptHash = digest.Hash;
                    break;
            }
            return Task.FromResult(SampleGateFixture.GeneratedResponse);
        });

        Assert.Equal(4, result);
        Assert.Equal(1, validationCalls);
        Assert.False(serverAccepted);
        fixture.AssertCalls(1, 1, 1, 1);
        fixture.AssertMatchingSubmission();
        Assert.Contains("HTTP 403", fixture.Error.ToString());
        Assert.Contains("Generation already completed", fixture.Error.ToString());
        Assert.DoesNotContain("No model call was made", fixture.Error.ToString());
    }

    [Fact]
    public async Task Unreported_remote_change_is_not_inferable_from_earlier_receipt()
    {
        using var fixture = new SampleGateFixture();
        var serverContextChanged = false;
        var callbackObservedChange = false;
        fixture.ExpectEvaluation();
        fixture.ExpectActivity(beforeResponse: () => serverContextChanged = true);
        fixture.Expect(SampleGateFixture.InteractionPath, _ => serverContextChanged
            ? SampleGateFixture.Rejection("PROMPT_EVALUATION_INVALID")
            : throw new OfflineProviderException());

        Assert.Equal(4, await fixture.RunAsync((_, _) =>
        {
            callbackObservedChange = serverContextChanged;
            return Task.FromResult(SampleGateFixture.GeneratedResponse);
        }));

        Assert.True(callbackObservedChange);
        fixture.AssertCalls(1, 1, 1, 1);
        fixture.AssertMatchingSubmission();
        Assert.Contains("Do not repeat the model call or ingestion blindly", fixture.Error.ToString());
    }
}
