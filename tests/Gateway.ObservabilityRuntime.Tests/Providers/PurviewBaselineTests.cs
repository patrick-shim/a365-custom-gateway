using System.Net;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.ObservabilityRuntime.Tests.Fixtures;

namespace Gateway.ObservabilityRuntime.Tests.Providers;

public sealed class PurviewBaselineTests
{
    internal static PurviewInteraction Interaction => new(
        FixtureIds.Agent, FixtureIds.Actor.ToString("D"), "offline-interaction",
        "synthetic positive", "text/plain", "synthetic response", "text/plain",
        "fixture", "fixture-model", FixtureIds.Child.ToString("D"), FixtureIds.Blueprint.ToString("D"),
        "Offline agent", FixtureIds.Timestamp, PurviewExecutionMode.EvaluateInline, "offline-correlation");

    private const string InlineScope = """
        {"value":[{"activities":"uploadText,downloadText","executionMode":"evaluateInline","policyActions":[]}]}
        """;
    private const string Allowed = """{"policyActions":[],"processingErrors":[],"protectionScopeState":"notModified"}""";
    private const string Modified = """{"policyActions":[],"processingErrors":[],"protectionScopeState":"modified"}""";
    private const string Blocked = """
        {"policyActions":[{"action":"restrictAccess","restrictionAction":"block"}],"processingErrors":[],"protectionScopeState":"notModified"}
        """;

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Inline_content_decisions_preserve_user_blueprint_and_child_binding(bool blocked)
    {
        using var fixture = new PurviewFixture();
        ExpectScope(fixture);
        ExpectContent(fixture, blocked ? Blocked : Allowed, inspect: request =>
        {
            Assert.Equal("\"scope-1\"", request.IfNoneMatch);
            Assert.Equal("Bearer", request.AuthorizationScheme);
            var metadata = request.Json.GetProperty("contentToProcess");
            Assert.Equal(FixtureIds.Blueprint.ToString("D"),
                metadata.GetProperty("protectedAppMetadata").GetProperty("applicationLocation").GetProperty("value").GetString());
            var entry = Assert.Single(metadata.GetProperty("contentEntries").EnumerateArray());
            Assert.Equal(Interaction.PromptContent, entry.GetProperty("content").GetProperty("data").GetString());
            var agent = Assert.Single(entry.GetProperty("agents").EnumerateArray());
            Assert.Equal(FixtureIds.Child.ToString("D"), agent.GetProperty("identifier").GetString());
            Assert.Equal(FixtureIds.Blueprint.ToString("D"), agent.GetProperty("blueprintId").GetString());
        });

        var result = await fixture.Client.EvaluatePromptAsync(Interaction, CancellationToken.None);

        Assert.Equal(!blocked, result.IsAllowed);
        Assert.Equal(blocked ? PurviewDecisionType.Blocked : PurviewDecisionType.Allowed, result.Decision);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Scope_level_block_does_not_send_raw_content()
    {
        using var fixture = new PurviewFixture();
        ExpectScope(fixture, """
            {"value":[{"activities":"uploadText","executionMode":"evaluateInline",
            "policyActions":[{"action":"restrictAccess","restrictionAction":"block"}]}]}
            """);

        var result = await fixture.Client.EvaluatePromptAsync(Interaction, CancellationToken.None);

        Assert.False(result.IsAllowed);
        Assert.DoesNotContain(Interaction.PromptContent, Assert.Single(fixture.Transport.Requests).Body);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(202)]
    [InlineData(204)]
    public async Task Accepted_without_inline_decision_is_not_enforcement(int status)
    {
        using var fixture = new PurviewFixture();
        ExpectScope(fixture);
        ExpectContent(fixture, "{}", (HttpStatusCode)status);

        var failure = await Assert.ThrowsAsync<PurviewPolicyException>(() =>
            fixture.Client.EvaluatePromptAsync(Interaction, CancellationToken.None));

        Assert.Equal("PURVIEW_INLINE_DECISION_MISSING", failure.FailureCode);
        Assert.True(failure.IsTransient);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Offline_audit_submits_two_metadata_activities_not_prompt_or_response()
    {
        using var fixture = new PurviewFixture();
        foreach (var activity in new[] { "uploadText", "downloadText" })
        {
            fixture.ExpectToken();
            fixture.Transport.Expect(HttpMethod.Post, PurviewFixture.UserUri("activities/contentActivities"),
                HttpStatusCode.Created, inspect: request =>
                {
                    Assert.DoesNotContain(Interaction.PromptContent, request.Body);
                    Assert.DoesNotContain(Interaction.ResponseContent, request.Body);
                    var metadata = request.Json.GetProperty("contentToProcess");
                    Assert.Equal(activity, metadata.GetProperty("activityMetadata").GetProperty("activity").GetString());
                    var entry = Assert.Single(metadata.GetProperty("contentEntries").EnumerateArray());
                    Assert.False(entry.TryGetProperty("content", out _));
                    Assert.False(entry.TryGetProperty("agents", out _));
                });
        }

        var result = await fixture.Client.EvaluateInteractionAsync(
            Interaction with { ExecutionMode = PurviewExecutionMode.EvaluateOffline }, CancellationToken.None);

        Assert.True(result.IsAllowed);
        Assert.Equal(PurviewDecisionType.AuditLogged, result.Decision);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Shared_blueprint_scope_is_cached_but_each_content_call_keeps_its_child_identity()
    {
        using var fixture = new PurviewFixture();
        ExpectScope(fixture);
        ExpectContent(fixture, Allowed);
        ExpectContent(fixture, Allowed, inspect: request =>
            Assert.Equal(FixtureIds.Principal.ToString("D"), request.Json.GetProperty("contentToProcess")
                .GetProperty("contentEntries")[0].GetProperty("agents")[0].GetProperty("identifier").GetString()));
        ExpectScope(fixture, actor: FixtureIds.Tenant);
        ExpectContent(fixture, Allowed, actor: FixtureIds.Tenant);

        await fixture.Client.EvaluatePromptAsync(Interaction, CancellationToken.None);
        await fixture.Client.EvaluatePromptAsync(Interaction with
        {
            AgentRegistrationId = FixtureIds.Registry,
            AgentIdentityClientId = FixtureIds.Principal.ToString("D")
        }, CancellationToken.None);
        await fixture.Client.EvaluatePromptAsync(Interaction with
        {
            TenantUserObjectId = FixtureIds.Tenant.ToString("D")
        }, CancellationToken.None);

        Assert.Equal(2, fixture.Transport.Requests.Count(request => request.Uri.AbsolutePath.EndsWith("/compute")));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Normal_evaluation_refreshes_a_modified_scope_at_most_once(bool stillModified)
    {
        using var fixture = new PurviewFixture();
        ExpectScope(fixture);
        ExpectContent(fixture, Modified);
        ExpectScope(fixture, etag: "\"scope-2\"");
        ExpectContent(fixture, stillModified ? Modified : Allowed, inspect: request =>
            Assert.Equal("\"scope-2\"", request.IfNoneMatch));

        if (stillModified)
        {
            var failure = await Assert.ThrowsAsync<PurviewPolicyException>(() =>
                fixture.Client.EvaluatePromptAsync(Interaction, CancellationToken.None));
            Assert.Equal("PURVIEW_SCOPE_UNSTABLE", failure.FailureCode);
            Assert.True(failure.IsTransient);
        }
        else
        {
            Assert.True((await fixture.Client.EvaluatePromptAsync(Interaction, CancellationToken.None)).IsAllowed);
        }

        Assert.Equal(4, fixture.Transport.Requests.Count);
        Assert.Equal(fixture.Transport.Requests[1].Body, fixture.Transport.Requests[3].Body);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Missing_scope_does_not_fall_back_to_allow_or_submit_content()
    {
        using var fixture = new PurviewFixture();
        ExpectScope(fixture, """{"value":[]}""");

        var failure = await Assert.ThrowsAsync<PurviewPolicyException>(() =>
            fixture.Client.EvaluatePromptAsync(Interaction, CancellationToken.None));

        Assert.Equal("PURVIEW_SCOPE_MISSING", failure.FailureCode);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Graph_failure_is_safe_and_not_a_policy_verdict()
    {
        using var fixture = new PurviewFixture();
        fixture.ExpectToken();
        fixture.Transport.Expect(HttpMethod.Post, PurviewFixture.UserUri("protectionScopes/compute"),
            HttpStatusCode.Forbidden, """{"error":{"code":"AccessDenied","message":"provider-private-content"}}""");

        var failure = await Assert.ThrowsAsync<PurviewPolicyException>(() =>
            fixture.Client.EvaluatePromptAsync(Interaction, CancellationToken.None));

        Assert.Equal("PURVIEW_GRAPH_HTTP_403_ACCESSDENIED", failure.FailureCode);
        Assert.False(failure.IsTransient);
        Assert.DoesNotContain("provider-private-content", failure.Message);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Disabled_client_never_resolves_a_provider_token()
    {
        using var fixture = new PurviewFixture(enabled: false);
        var failure = await Assert.ThrowsAsync<PurviewPolicyException>(() =>
            fixture.Client.EvaluatePromptAsync(Interaction, CancellationToken.None));
        Assert.Equal("PURVIEW_NOT_CONFIGURED", failure.FailureCode);
        Assert.Empty(fixture.Tokens.Calls.Requests);
        Assert.Empty(fixture.Transport.Requests);
        fixture.AssertComplete();
    }

    private static void ExpectScope(PurviewFixture fixture, string body = InlineScope, string etag = "\"scope-1\"", Guid? actor = null)
    {
        fixture.ExpectToken();
        fixture.Transport.Expect(HttpMethod.Post, PurviewFixture.UserUri("protectionScopes/compute", actor),
            HttpStatusCode.OK, body, etag, request =>
            {
                Assert.Null(request.IfNoneMatch);
                Assert.Equal(FixtureIds.Blueprint.ToString("D"), request.Json.GetProperty("locations")[0].GetProperty("value").GetString());
            });
    }

    private static void ExpectContent(PurviewFixture fixture, string body, HttpStatusCode status = HttpStatusCode.OK,
        Action<CapturedRequest>? inspect = null, Guid? actor = null)
    {
        fixture.ExpectToken();
        fixture.Transport.Expect(HttpMethod.Post, PurviewFixture.UserUri("processContent", actor), status, body, inspect: inspect);
    }
}
