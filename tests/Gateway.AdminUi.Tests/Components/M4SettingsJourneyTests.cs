using System.Text.Json;
using Bunit;
using Gateway.AdminUi.Components.Pages;
using Gateway.AdminUi.Components.Shared;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.AdminUi.Tests.Fixtures;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Microsoft.AspNetCore.Components;
using Microsoft.AspNetCore.Components.Forms;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Time.Testing;
using Microsoft.JSInterop;

namespace Gateway.AdminUi.Tests.Components;

public sealed partial class M4SettingsJourneyTests
{
    private static readonly Guid ConnectionId = Guid.Parse("99999999-9999-4999-8999-999999999991");
    private static readonly Guid InventoryId = Guid.Parse("99999999-9999-4999-8999-999999999992");
    private static readonly Guid SitId = Guid.Parse("99999999-9999-4999-8999-999999999993");
    private static readonly Guid ReviewId = Guid.Parse("99999999-9999-4999-8999-999999999994");
    private static readonly Guid OtherActor = Guid.Parse("99999999-9999-4999-8999-999999999995");
    private static readonly Guid CompletionReviewId = Guid.Parse("99999999-9999-4999-8999-999999999997");
    private const string ConnectionAction = "ConnectPurviewTenant";
    private static DateTime Now => CoreUiData.Now.UtcDateTime;
    private static string Hash => "sha256:" + new string('a', 64);

    [Theory]
    [InlineData("Gateway.Administrator")]
    [InlineData("Gateway.Operator")]
    [InlineData("Gateway.Auditor")]
    [InlineData("Gateway.SupportReader")]
    public void Core_only_overview_is_complete_and_optional(string role)
    {
        using var fixture = CoreUiData.Create(role);
        ExpectCapabilities(fixture, installed: false);
        if (role == "Gateway.Administrator")
            ExpectConfig(fixture);
        var page = fixture.Render<Settings>();
        Assert.Contains("Both protections Off is a complete core registration", page.Markup);
        Assert.Empty(page.FindAll("#purview-journey-heading, #defaults-heading, textarea"));
        Assert.Empty(page.FindAll("[role='alert']"));
        fixture.AssertComplete();
    }

    [Fact]
    public void Connection_task_does_not_render_unrelated_editors()
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture);
        var page = ConnectionPage(fixture);
        Assert.NotEmpty(page.FindAll("#purview-connection-heading"));
        Assert.Empty(page.FindAll("#dlp-review-form-heading, #defaults-heading, #kyd-mode, textarea"));
        Assert.Contains(AdminUiFixture.Tenant.ToString("D"), page.Markup);
        Assert.Contains(AdminUiFixture.Actor.ToString("D"), page.Markup);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Old_operation_errors_do_not_disable_a_clean_task(bool notFound)
    {
        using var fixture = CoreUiData.Create();
        var navigation = fixture.Services.GetRequiredService<NavigationManager>();
        navigation.NavigateTo("/settings/connection?operation=" + (notFound ? ReviewId.ToString("D") : "invalid"));
        ExpectCapabilities(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(null)));
        if (notFound)
            fixture.Script.Expect<GatewayApiResource<ProtectionAdminOperationResponse>>(
                nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
                _ => Task.FromException<GatewayApiResource<ProtectionAdminOperationResponse>>(CoreUiData.Error(System.Net.HttpStatusCode.NotFound)));
        ExpectConfig(fixture);
        var page = fixture.Render<Settings>(parameters => parameters.Add(item => item.TaskName, "connection"));
        Assert.NotEmpty(page.FindAll("[role='alert']"));
        ExpectConnectionLoad(fixture);
        await page.InvokeAsync(() => navigation.NavigateTo("/settings/connection"));
        ExpectConnectionReview(fixture);
        await AdminUiFixture.ClickAsync(page, "Review tenant connection");
        Assert.Single(page.FindComponents<ConfirmPanel>());
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("Gateway.Operator", "runtime")]
    [InlineData("Gateway.Auditor", "runtime")]
    [InlineData("Gateway.SupportReader", "runtime")]
    [InlineData("Gateway.Operator", "defaults")]
    [InlineData("Gateway.Auditor", "defaults")]
    [InlineData("Gateway.SupportReader", "defaults")]
    public void Restricted_task_never_reads_administrator_data(string role, string task)
    {
        using var fixture = CoreUiData.Create(role);
        ExpectCapabilities(fixture);
        var page = fixture.Render<Settings>(parameters => parameters.Add(item => item.TaskName, task));
        Assert.Contains("Gateway Administrator role", page.Markup);
        Assert.Single(page.FindAll("h1"));
        Assert.Empty(page.FindAll("textarea, #defaults-heading"));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Cancelled_connection_review_rejects_a_late_confirmation_callback()
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture);
        var page = ConnectionPage(fixture);
        var review = ExpectConnectionReview(fixture);
        await AdminUiFixture.ClickAsync(page, "Review tenant connection");
        var callback = page.FindComponent<ConfirmPanel>().Instance.OnConfirm;
        await AdminUiFixture.ClickAsync(page, "Cancel");
        await page.InvokeAsync(() => callback.InvokeAsync());
        Assert.False(review.IsAvailable);
        Assert.Contains("Review cancelled", page.Markup);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("DlpProfile", "Tenant")]
    [InlineData("PurviewTenantConnection", "Individual")]
    public async Task Mismatched_connection_review_scope_never_reaches_confirmation(string targetType, string scope)
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture);
        var page = ConnectionPage(fixture);
        var review = ExpectConnectionReview(fixture, targetType, scope);
        await AdminUiFixture.ClickAsync(page, "Review tenant connection");
        Assert.False(review.IsAvailable);
        Assert.Empty(page.FindComponents<ConfirmPanel>());
        Assert.Contains("did not match the exact operation", page.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Expired_review_does_not_send_confirmation_or_mutation()
    {
        using var fixture = CoreUiData.Create();
        var clock = Clock(fixture);
        ExpectConnectionLoad(fixture);
        var page = ConnectionPage(fixture);
        ExpectConnectionReview(fixture);
        await AdminUiFixture.ClickAsync(page, "Review tenant connection");
        var callback = page.FindComponent<ConfirmPanel>().Instance.OnConfirm;
        clock.Advance(TimeSpan.FromMinutes(1));
        await page.InvokeAsync(() => callback.InvokeAsync());
        Assert.Contains("review expired or its context changed", page.Markup);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    public async Task Failed_browser_recovery_retention_sends_no_authorization(int failure)
    {
        using var fixture = CoreUiData.Create();
        var retention = fixture.JSInterop.Setup<bool>("A365Gateway.retainProtectionRecovery", _ => true);
        if (failure == 0)
            retention.SetResult(false);
        else
            retention.SetException<Exception>(failure switch
            {
                1 => new JSDisconnectedException("Synthetic private diagnostic."),
                2 => new JSException("Synthetic private diagnostic."),
                _ => new TaskCanceledException("Synthetic private diagnostic.")
            });
        ExpectConnectionLoad(fixture);
        var page = ConnectionPage(fixture);
        ExpectConnectionReview(fixture);
        await AdminUiFixture.ClickAsync(page, "Review tenant connection");
        await AdminUiFixture.ClickAsync(page, "Confirm and start");
        Assert.Empty(page.FindAll("a[download]"));
        Assert.Contains("No confirmation or protection change was sent", page.Markup);
        Assert.Contains("Reload this page", page.Markup);
        Assert.DoesNotContain("Synthetic private diagnostic", page.Markup);
        Assert.DoesNotContain("The gateway could not complete the request", page.Markup);
        Assert.DoesNotContain(nameof(IGatewayApiClient.ConfirmProtectionOperationReviewAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Browser_retention_is_acknowledged_before_confirmation_and_start()
    {
        using var fixture = CoreUiData.Create();
        var retention = fixture.JSInterop.Setup<bool>("A365Gateway.retainProtectionRecovery", _ => true);
        ExpectConnectionLoad(fixture);
        var page = ConnectionPage(fixture);
        var review = ExpectConnectionReview(fixture);
        await AdminUiFixture.ClickAsync(page, "Review tenant connection");
        ExpectConfirmedStart(fixture, review);
        var confirm = AdminUiFixture.ClickAsync(page, "Confirm and start");
        page.WaitForAssertion(() => Assert.Contains(fixture.JSInterop.Invocations,
            invocation => invocation.Identifier == "A365Gateway.retainProtectionRecovery"));
        Assert.DoesNotContain(nameof(IGatewayApiClient.ConfirmProtectionOperationReviewAsync), fixture.Script.Calls);
        retention.SetResult(true);
        await confirm;
        Assert.Contains("Download the Windows Purview companion", page.Markup);
        Assert.False(review.IsAvailable);
        Assert.Equal(1, fixture.Script.Calls.Count(call => call == nameof(IGatewayApiClient.StartPurviewTenantConnectionOperationAsync)));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Leaving_the_task_while_browser_retention_is_pending_cannot_dispatch()
    {
        using var fixture = CoreUiData.Create();
        var retention = fixture.JSInterop.Setup<bool>("A365Gateway.retainProtectionRecovery", _ => true);
        ExpectConnectionLoad(fixture);
        var page = ConnectionPage(fixture);
        var review = ExpectConnectionReview(fixture);
        await AdminUiFixture.ClickAsync(page, "Review tenant connection");
        var confirm = AdminUiFixture.ClickAsync(page, "Confirm and start");
        page.WaitForAssertion(() => Assert.Contains(fixture.JSInterop.Invocations,
            invocation => invocation.Identifier == "A365Gateway.retainProtectionRecovery"));
        ExpectCapabilities(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(null)));
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewDlpProfilesAsync),
            CoreUiData.Resource(new PurviewDlpProfileListResponse([])));
        ExpectConfig(fixture);
        page.Render(parameters => parameters.Add(item => item.TaskName, "defaults"));
        retention.SetResult(true);
        await confirm;
        Assert.False(review.IsAvailable);
        Assert.Empty(page.FindComponents<ConfirmPanel>());
        Assert.DoesNotContain(nameof(IGatewayApiClient.ConfirmProtectionOperationReviewAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Unknown_start_reads_the_same_operation_without_recreating()
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture);
        var page = ConnectionPage(fixture);
        var review = ExpectConnectionReview(fixture);
        await AdminUiFixture.ClickAsync(page, "Review tenant connection");
        ExpectConfirmation(fixture, review);
        fixture.Script.Expect<GatewayApiResource<ProtectionOperationAcceptedResponse>>(
            nameof(IGatewayApiClient.StartPurviewTenantConnectionOperationAsync),
            _ => Task.FromException<GatewayApiResource<ProtectionOperationAcceptedResponse>>(
                new GatewayApiTransportException("Synthetic response loss.", "fixture-correlation", new HttpRequestException("Synthetic transport."))));
        await AdminUiFixture.ClickAsync(page, "Confirm and start");
        Assert.Contains("The protection result is not confirmed", page.Markup);
        ExpectOperation(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(Connection())));
        await AdminUiFixture.ClickAsync(page, "Check existing operation");
        Assert.Contains("Download the Windows Purview companion", page.Markup);
        Assert.Equal(1, fixture.Script.Calls.Count(call => call == nameof(IGatewayApiClient.StartPurviewTenantConnectionOperationAsync)));
        fixture.AssertComplete();
    }

    [Fact]
    public void Reopen_recovers_accepted_launch_without_reauthorizing()
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        Assert.Contains("Download the Windows Purview companion", page.Markup);
        Assert.Contains(InventoryId.ToString("D"), page.Markup);
        Assert.DoesNotContain("synthetic-review-token", page.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public void Another_administrator_cannot_upload_or_run_the_original_companion()
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection(), operation: true, actor: OtherActor);
        var page = ConnectionPage(fixture, reopen: true);
        Assert.Contains("belongs to another administrator", page.Markup);
        Assert.Empty(page.FindAll("a[download]"));
        Assert.True(page.Find("#purview-companion-evidence").HasAttribute("disabled"));
        Assert.True(page.Find("#purview-companion-output").HasAttribute("disabled"));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("tenant")]
    [InlineData("actor")]
    [InlineData("operation")]
    [InlineData("generation")]
    [InlineData("future")]
    [InlineData("duplicate")]
    public void Mismatched_companion_output_cannot_reach_review(string mismatch)
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        page.FindComponent<InputFile>().UploadFiles(InputFileContent.CreateFromText(Output(mismatch), "synthetic-connection.txt"));
        page.WaitForAssertion(() => Assert.Contains("not the single fresh result", page.Markup));
        fixture.AssertComplete();
    }

    [Fact]
    public void Matching_companion_output_becomes_reviewable_but_does_not_claim_connection_success()
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        page.FindComponent<InputFile>().UploadFiles(InputFileContent.CreateFromText(Output(), "synthetic-connection.txt"));
        page.WaitForAssertion(() => Assert.Contains("Evidence checked for this tenant", page.Markup));
        Assert.DoesNotContain("Connection verified", page.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Completion_retention_exception_preserves_evidence_and_sends_no_confirmation()
    {
        using var fixture = CoreUiData.Create();
        fixture.JSInterop.Setup<bool>("A365Gateway.retainProtectionRecovery", _ => true)
            .SetException(new JSException("Synthetic private recovery detail."));
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        var review = await ReviewCompletionAsync(fixture, page);

        await AdminUiFixture.ClickAsync(page, "Submit for verification");

        Assert.Contains("No confirmation or protection change was sent", page.Markup);
        Assert.Contains("Reload this page", page.Markup);
        Assert.DoesNotContain("Synthetic private recovery detail", page.Markup);
        Assert.DoesNotContain("The protection result is not confirmed", page.Markup);
        Assert.Contains("Evidence checked for this tenant", page.Markup);
        Assert.Contains($"operation={ReviewId:D}", fixture.Services.GetRequiredService<NavigationManager>().Uri);
        Assert.False(review.IsAvailable);
        Assert.DoesNotContain(nameof(IGatewayApiClient.ConfirmProtectionOperationReviewAsync), fixture.Script.Calls);
        Assert.DoesNotContain(nameof(IGatewayApiClient.CompletePurviewTenantConnectionOperationAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Completion_retains_the_source_operation_before_confirmation_and_accepts_its_response()
    {
        using var fixture = CoreUiData.Create();
        var retention = fixture.JSInterop.Setup<bool>("A365Gateway.retainProtectionRecovery", _ => true);
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        var review = await ReviewCompletionAsync(fixture, page);
        ExpectConfirmation(fixture, review);
        fixture.Script.Return(nameof(IGatewayApiClient.CompletePurviewTenantConnectionOperationAsync),
            CoreUiData.Resource(new ProtectionOperationAcceptedResponse(ReviewId, "Pending", ReviewId)),
            arguments =>
            {
                Assert.Equal(ReviewId, Assert.IsType<Guid>(arguments[0]));
                Assert.Equal(CompletionReviewId,
                    Assert.IsType<ProtectionOperationConfirmationTicket>(arguments[2]).ReviewTokenId);
            });
        ExpectPendingConnectionReadback(fixture);

        var submission = AdminUiFixture.ClickAsync(page, "Submit for verification");
        page.WaitForAssertion(() => Assert.Contains(fixture.JSInterop.Invocations,
            invocation => invocation.Identifier == "A365Gateway.retainProtectionRecovery"));
        var invocation = fixture.JSInterop.Invocations.Last(item =>
            item.Identifier == "A365Gateway.retainProtectionRecovery");
        Assert.Equal(ReviewId.ToString("D"), invocation.Arguments[1]);
        Assert.Contains($"operation={ReviewId:D}", Assert.IsType<string>(invocation.Arguments[0]));
        Assert.DoesNotContain(nameof(IGatewayApiClient.ConfirmProtectionOperationReviewAsync), fixture.Script.Calls);
        retention.SetResult(true);
        await submission;

        Assert.Contains($"operation={ReviewId:D}", fixture.Services.GetRequiredService<NavigationManager>().Uri);
        Assert.DoesNotContain("did not identify the reviewed operation", page.Markup);
        Assert.DoesNotContain("The protection result is not confirmed", page.Markup);
        Assert.DoesNotContain("Connection verified", page.Markup);
        Assert.Empty(page.FindAll("a[download]"));
        Assert.False(review.IsAvailable);
        Assert.Equal(1, fixture.Script.Calls.Count(call =>
            call == nameof(IGatewayApiClient.CompletePurviewTenantConnectionOperationAsync)));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Lost_completion_response_reads_the_source_operation_without_resubmission()
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        var review = await ReviewCompletionAsync(fixture, page);
        ExpectConfirmation(fixture, review);
        fixture.Script.Expect<GatewayApiResource<ProtectionOperationAcceptedResponse>>(
            nameof(IGatewayApiClient.CompletePurviewTenantConnectionOperationAsync),
            _ => Task.FromException<GatewayApiResource<ProtectionOperationAcceptedResponse>>(
                new GatewayApiTransportException("Synthetic response loss.", "fixture-correlation",
                    new HttpRequestException("Synthetic transport."))));
        await AdminUiFixture.ClickAsync(page, "Submit for verification");
        Assert.Contains("The protection result is not confirmed", page.Markup);
        Assert.Contains($"operation={ReviewId:D}", fixture.Services.GetRequiredService<NavigationManager>().Uri);

        ExpectPendingConnectionReadback(fixture);
        await AdminUiFixture.ClickAsync(page, "Check existing operation");
        Assert.DoesNotContain("The protection result is not confirmed", page.Markup);
        Assert.DoesNotContain("Synthetic response loss.", page.Markup);
        Assert.Empty(page.FindAll("a[download]"));
        Assert.DoesNotContain("Finish on Windows", page.Markup);
        Assert.Equal(1, fixture.Script.Calls.Count(call =>
            call == nameof(IGatewayApiClient.CompletePurviewTenantConnectionOperationAsync)));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Completion_rejects_an_authorization_or_unrelated_id_as_the_continued_operation(bool unrelated)
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        var review = await ReviewCompletionAsync(fixture, page);
        ExpectConfirmation(fixture, review);
        var responseId = unrelated ? OtherActor : CompletionReviewId;
        fixture.Script.Return(nameof(IGatewayApiClient.CompletePurviewTenantConnectionOperationAsync),
            CoreUiData.Resource(new ProtectionOperationAcceptedResponse(responseId, "Pending", responseId)));
        await AdminUiFixture.ClickAsync(page, "Submit for verification");
        Assert.Contains("did not identify the reviewed operation", page.Markup);
        Assert.Contains("The protection result is not confirmed", page.Markup);
        Assert.Contains($"operation={ReviewId:D}", fixture.Services.GetRequiredService<NavigationManager>().Uri);
        Assert.DoesNotContain(nameof(IGatewayApiClient.StartPurviewTenantConnectionOperationAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public void Reopening_a_submitted_completion_follows_its_exact_source_readback()
    {
        using var fixture = CoreUiData.Create();
        fixture.Services.GetRequiredService<NavigationManager>()
            .NavigateTo($"/settings/connection?operation={CompletionReviewId:D}");
        ExpectCapabilities(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(Connection("PendingVerification"))));
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
            CoreUiData.Resource(new ProtectionAdminOperationResponse(SubmittedCompletion())),
            arguments => Assert.Equal(CompletionReviewId, Assert.IsType<Guid>(arguments[0])));
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
            CoreUiData.Resource(new ProtectionAdminOperationResponse(PendingConnection())),
            arguments => Assert.Equal(ReviewId, Assert.IsType<Guid>(arguments[0])));
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(Connection("PendingVerification"))));
        ExpectConfig(fixture);
        var page = fixture.Render<Settings>(parameters => parameters.Add(item => item.TaskName, "connection"));

        Assert.Contains($"operation={ReviewId:D}", fixture.Services.GetRequiredService<NavigationManager>().Uri);
        Assert.DoesNotContain("The protection result is not confirmed", page.Markup);
        Assert.Empty(page.FindAll("a[download]"));
        Assert.DoesNotContain(nameof(IGatewayApiClient.CompletePurviewTenantConnectionOperationAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("id")]
    [InlineData("tenant")]
    [InlineData("actor")]
    [InlineData("type")]
    [InlineData("target")]
    [InlineData("waiting")]
    public void Completion_readback_rejects_a_different_or_unaccepted_source(string mismatch)
    {
        using var fixture = CoreUiData.Create();
        var navigation = fixture.Services.GetRequiredService<NavigationManager>();
        navigation.NavigateTo($"/settings/connection?operation={CompletionReviewId:D}");
        ExpectCapabilities(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(Connection("PendingVerification"))));
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
            CoreUiData.Resource(new ProtectionAdminOperationResponse(SubmittedCompletion())));
        var source = mismatch switch
        {
            "id" => PendingConnection() with { Id = OtherActor },
            "tenant" => PendingConnection() with { TenantId = OtherActor },
            "actor" => PendingConnection() with { ActorObjectId = OtherActor.ToString("D") },
            "type" => PendingConnection() with { Type = "CreateOrUpdateDlpProfile" },
            "target" => PendingConnection() with { TargetIdentifier = OtherActor.ToString("D") },
            _ => Operation()
        };
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
            CoreUiData.Resource(new ProtectionAdminOperationResponse(source)));
        ExpectConfig(fixture);
        var page = fixture.Render<Settings>(parameters => parameters.Add(item => item.TaskName, "connection"));
        Assert.Contains("completion readback did not match", page.Markup);
        Assert.Contains($"operation={CompletionReviewId:D}", navigation.Uri);
        Assert.Empty(page.FindAll("a[download]"));
        Assert.DoesNotContain("Connection verified", page.Markup);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("missing")]
    [InlineData("empty")]
    [InlineData("self")]
    [InlineData("target-type")]
    [InlineData("target-format")]
    public void Invalid_completion_references_do_not_fetch_a_source_or_allow_another_mutation(string fault)
    {
        using var fixture = CoreUiData.Create();
        fixture.Services.GetRequiredService<NavigationManager>()
            .NavigateTo($"/settings/connection?operation={CompletionReviewId:D}");
        ExpectCapabilities(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(Connection("PendingVerification"))));
        var completion = fault switch
        {
            "missing" => SubmittedCompletion() with { ReadbackReferenceId = null },
            "empty" => SubmittedCompletion() with { ReadbackReferenceId = Guid.Empty },
            "self" => SubmittedCompletion() with { ReadbackReferenceId = CompletionReviewId },
            "target-type" => SubmittedCompletion() with { TargetType = "DlpProfile" },
            _ => SubmittedCompletion() with { TargetIdentifier = "not-an-identifier" }
        };
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
            CoreUiData.Resource(new ProtectionAdminOperationResponse(completion)));
        ExpectConfig(fixture);
        var page = fixture.Render<Settings>(parameters => parameters.Add(item => item.TaskName, "connection"));
        Assert.Contains("completion readback did not match", page.Markup);
        Assert.True(ConnectionRefreshDisabled(page));
        Assert.Equal(1, fixture.Script.Calls.Count(call => call == nameof(IGatewayApiClient.GetProtectionAdminOperationAsync)));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Failed_completion_retention_sends_neither_confirmation_nor_submission(bool disconnected)
    {
        using var fixture = CoreUiData.Create();
        var retention = fixture.JSInterop.Setup<bool>("A365Gateway.retainProtectionRecovery", _ => true);
        if (disconnected)
            retention.SetException(new JSDisconnectedException("Synthetic disconnect."));
        else
            retention.SetResult(false);
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        var review = await ReviewCompletionAsync(fixture, page);
        await AdminUiFixture.ClickAsync(page, "Submit for verification");
        Assert.False(review.IsAvailable);
        Assert.Contains($"operation={ReviewId:D}", fixture.Services.GetRequiredService<NavigationManager>().Uri);
        Assert.DoesNotContain(nameof(IGatewayApiClient.ConfirmProtectionOperationReviewAsync), fixture.Script.Calls);
        Assert.DoesNotContain(nameof(IGatewayApiClient.CompletePurviewTenantConnectionOperationAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Late_completion_readback_after_disposal_cannot_change_the_retained_operation(bool failedRead)
    {
        using var fixture = CoreUiData.Create();
        var navigation = fixture.Services.GetRequiredService<NavigationManager>();
        navigation.NavigateTo($"/settings/connection?operation={CompletionReviewId:D}");
        ExpectCapabilities(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(Connection("PendingVerification"))));
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
            CoreUiData.Resource(new ProtectionAdminOperationResponse(
                SubmittedCompletion() with { Status = "AwaitingConfirmation", ReadbackReferenceId = null })));
        ExpectConfig(fixture);
        var page = fixture.Render<Settings>(parameters => parameters.Add(item => item.TaskName, "connection"));
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
            CoreUiData.Resource(new ProtectionAdminOperationResponse(SubmittedCompletion())));
        var source = new TaskCompletionSource<GatewayApiResource<ProtectionAdminOperationResponse>>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Script.Expect<GatewayApiResource<ProtectionAdminOperationResponse>>(
            nameof(IGatewayApiClient.GetProtectionAdminOperationAsync), _ => source.Task);
        var refresh = AdminUiFixture.ClickAsync(page, "Check existing operation");
        page.WaitForAssertion(() => Assert.Equal(3, fixture.Script.Calls.Count(
            call => call == nameof(IGatewayApiClient.GetProtectionAdminOperationAsync))));

        await page.InvokeAsync(() => page.Instance.DisposeAsync().AsTask());
        if (failedRead)
            source.SetException(new HttpRequestException("Synthetic late read failure."));
        else
            source.SetResult(CoreUiData.Resource(new ProtectionAdminOperationResponse(PendingConnection())));
        await refresh;
        Assert.Contains($"operation={CompletionReviewId:D}", navigation.Uri);
        Assert.DoesNotContain(nameof(IGatewayApiClient.CompletePurviewTenantConnectionOperationAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void Failed_provider_verification_displays_its_reference_without_claiming_connection_success(bool expired)
    {
        using var fixture = CoreUiData.Create();
        ExpectCapabilities(fixture);
        var failed = Connection("VerificationFailed") with
        {
            LastFailureCode = "PURVIEW_CONNECTION_PROVIDER_UNVERIFIED",
            ExpiresAtUtc = expired ? Now.AddMinutes(-1) : Connection().ExpiresAtUtc
        };
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(failed)));
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
            CoreUiData.Resource(new ProtectionAdminOperationResponse(Operation() with
            {
                Status = "Failed", RequiredAction = null, FailureCode = failed.LastFailureCode
            })));
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(failed)));
        ExpectConfig(fixture);
        var page = ConnectionPage(fixture, reopen: true);
        Assert.Contains("Connection verification failed.", page.Markup);
        Assert.Contains(failed.LastFailureCode, page.Find(".operation-failure-code").TextContent);
        Assert.Contains("DLP protection is not enabled by this step.", page.Markup);
        Assert.Contains("UTC", page.Find(".operation-meta time").TextContent);
        Assert.DoesNotContain("Connection verified", page.Markup);
        Assert.DoesNotContain("Awaiting admin", page.Markup);
        Assert.DoesNotContain("Refresh required", page.Markup);
        Assert.Empty(page.FindAll("a[download]"));
        fixture.AssertComplete();
    }

    [Fact]
    public void Launch_expiry_disables_upload_at_equality()
    {
        using var fixture = CoreUiData.Create();
        var clock = Clock(fixture);
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        Assert.False(page.Find("#purview-companion-evidence").HasAttribute("disabled"));
        clock.Advance(TimeSpan.FromMinutes(10));
        page.WaitForAssertion(() =>
        {
            Assert.True(page.Find("#purview-companion-evidence").HasAttribute("disabled"));
            Assert.True(page.Find("#purview-companion-output").HasAttribute("disabled"));
            Assert.Empty(page.FindAll("a[download]"));
        });
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Expired_connection_can_review_a_new_authorization_without_reusing_its_launch(bool reopen)
    {
        using var fixture = CoreUiData.Create();
        var clock = Clock(fixture);
        ExpectConnectionLoad(fixture, Connection(), operation: reopen);
        var page = ConnectionPage(fixture, reopen);
        Assert.True(ConnectionRefreshDisabled(page));

        clock.Advance(TimeSpan.FromMinutes(10));
        page.WaitForAssertion(() =>
        {
            Assert.False(ConnectionRefreshDisabled(page));
            Assert.Contains("Connection launch expired", page.Markup);
            Assert.Empty(page.FindAll("a[download]"));
        });
        var review = ExpectConnectionReview(fixture,
            expectedRowVersion: CoreUiData.Version,
            operationId: Guid.Parse("99999999-9999-4999-8999-999999999996"));
        await AdminUiFixture.ClickAsync(page, "Review connection refresh");

        Assert.Single(page.FindComponents<ConfirmPanel>());
        Assert.True(review.IsAvailable);
        Assert.DoesNotContain(nameof(IGatewayApiClient.StartPurviewTenantConnectionOperationAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Expired_connection_refresh_confirms_a_new_operation_and_inventory_generation()
    {
        using var fixture = CoreUiData.Create();
        var clock = Clock(fixture);
        fixture.JSInterop.Setup<bool>("A365Gateway.retainProtectionRecovery", _ => true).SetResult(true);
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        clock.Advance(TimeSpan.FromMinutes(10));
        page.WaitForAssertion(() => Assert.False(ConnectionRefreshDisabled(page)));

        var operationId = Guid.Parse("99999999-9999-4999-8999-999999999996");
        var inventoryId = Guid.Parse("99999999-9999-4999-8999-999999999997");
        var launch = Launch(operationId, inventoryId, clock.GetUtcNow().AddMinutes(15));
        var review = ExpectConnectionReview(fixture,
            expectedRowVersion: CoreUiData.Version,
            operationId: operationId);
        await AdminUiFixture.ClickAsync(page, "Review connection refresh");
        ExpectConfirmation(fixture, review);
        fixture.Script.Return(nameof(IGatewayApiClient.StartPurviewTenantConnectionOperationAsync),
            CoreUiData.Resource(new ProtectionOperationAcceptedResponse(
                operationId, "AwaitingAdministrator", operationId, launch)));
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
            CoreUiData.Resource(new ProtectionAdminOperationResponse(Operation() with { Id = operationId }, launch)),
            arguments => Assert.Equal(operationId, Assert.IsType<Guid>(arguments[0])));
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(Connection() with
            {
                ExpiresAtUtc = launch.ExpiresAtUtc.UtcDateTime
            })));

        await AdminUiFixture.ClickAsync(page, "Confirm and start");

        var command = Assert.Single(page.FindComponents<CopyableCommand>()).Instance.Command;
        Assert.Contains(operationId.ToString("D"), command);
        Assert.Contains(inventoryId.ToString("D"), command);
        Assert.DoesNotContain(ReviewId.ToString("D"), command);
        Assert.DoesNotContain(InventoryId.ToString("D"), command);
        Assert.Contains(launch.ExpiresAtUtc.ToString("O"), command);
        Assert.True(ConnectionRefreshDisabled(page));
        Assert.False(review.IsAvailable);
        Assert.Single(fixture.Script.Calls,
            call => call == nameof(IGatewayApiClient.StartPurviewTenantConnectionOperationAsync));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("live")]
    [InlineData("other-actor")]
    [InlineData("other-tenant")]
    [InlineData("pending-operation")]
    [InlineData("running-operation")]
    [InlineData("pending-verification")]
    [InlineData("missing-launch")]
    [InlineData("changed-expiry")]
    [InlineData("bad-command")]
    public async Task Connection_refresh_does_not_replace_live_unknown_or_mismatched_work(string fault)
    {
        using var fixture = CoreUiData.Create();
        var clock = Clock(fixture);
        var connection = Connection();
        var operation = Operation();
        PurviewCompanionLaunchDto? launch = Launch();
        switch (fault)
        {
            case "other-actor":
                operation = Operation(OtherActor);
                break;
            case "other-tenant":
                connection = connection with { TenantId = OtherActor };
                break;
            case "pending-operation":
                operation = operation with { Status = "Pending" };
                break;
            case "running-operation":
                operation = operation with { Status = "Running" };
                break;
            case "pending-verification":
                connection = connection with { Status = "PendingVerification" };
                operation = operation with { Type = "CompletePurviewTenantConnection", Status = "Pending" };
                break;
            case "missing-launch":
                launch = null;
                break;
            case "changed-expiry":
                connection = connection with { ExpiresAtUtc = Now.AddMinutes(9) };
                break;
            case "bad-command":
                launch = launch with { Arguments = [] };
                break;
        }
        ExpectCapabilities(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(connection)));
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
            CoreUiData.Resource(new ProtectionAdminOperationResponse(operation, launch)));
        if (fault is "pending-operation" or "running-operation")
            fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
                CoreUiData.Resource(new PurviewTenantConnectionResponse(Connection("PendingVerification"))));
        ExpectConfig(fixture);
        var page = ConnectionPage(fixture, reopen: true);
        if (fault is "pending-operation" or "running-operation")
            await AdminUiFixture.ClickAsync(page, "Stop automatic updates");
        if (fault != "live")
            clock.Advance(TimeSpan.FromMinutes(10));

        page.WaitForAssertion(() => Assert.True(ConnectionRefreshDisabled(page)));
        await AdminUiFixture.ClickAsync(page, "Review connection refresh");

        Assert.Empty(page.FindComponents<ConfirmPanel>());
        Assert.DoesNotContain(nameof(IGatewayApiClient.ReviewPurviewTenantConnectionAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public void Expired_connection_guidance_does_not_offer_an_administrator_action_to_an_operator()
    {
        using var fixture = CoreUiData.Create("Gateway.Operator");
        var clock = Clock(fixture);
        ExpectCapabilities(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(Connection())));
        var page = ConnectionPage(fixture);
        clock.Advance(TimeSpan.FromMinutes(10));

        page.WaitForAssertion(() =>
        {
            Assert.Contains("Connection launch expired", page.Markup);
            Assert.Contains("A Gateway Administrator must check", page.Markup);
            Assert.DoesNotContain("Select Review connection refresh", page.Markup);
        });
        Assert.DoesNotContain(nameof(IGatewayApiClient.ReviewPurviewTenantConnectionAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public void Connection_summarizes_inventory_without_a_selector_and_expires_at_equality()
    {
        using var fixture = CoreUiData.Create();
        var clock = Clock(fixture);
        ExpectConnectionLoad(fixture, Connection("Connected"), inventory: Inventory());
        var page = ConnectionPage(fixture);
        Assert.Empty(page.FindAll("#purview-sensitive-information-type"));
        Assert.Contains("1 existing sensitive information type found", page.Find("[data-testid='tenant-inventory-count']").TextContent);
        Assert.Contains("nothing to select here", page.Markup);
        Assert.Single(page.FindAll("nav[aria-label='Purview setup steps'] a[aria-current='step']"));
        Assert.Equal(4, page.FindAll(".protection-setup-steps > li").Count);
        Assert.DoesNotContain("Optional data collection", page.Find(".protection-setup-steps").TextContent);
        clock.Advance(TimeSpan.FromMinutes(5));
        page.WaitForAssertion(() =>
        {
            Assert.Empty(page.FindAll("#purview-sensitive-information-type"));
            Assert.Contains("Refresh required", page.Markup);
            Assert.DoesNotContain("catalog is ready for policy review", page.Markup);
        });
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Wrong_tenant_connection_is_not_verified_or_mutable()
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection("Connected") with { TenantId = OtherActor });
        var page = ConnectionPage(fixture);
        Assert.Contains("belongs to another tenant", page.Markup);
        Assert.DoesNotContain("Connection verified", page.Markup);
        await AdminUiFixture.ClickAsync(page, "Review connection refresh");
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("tenant")]
    [InlineData("generation")]
    [InlineData("duplicate")]
    [InlineData("expired")]
    public void Invalid_inventory_cannot_offer_selection_or_claim_current_catalog(string fault)
    {
        using var fixture = CoreUiData.Create();
        var inventory = Inventory();
        inventory = fault switch
        {
            "tenant" => inventory with { TenantId = OtherActor },
            "generation" => inventory with { GenerationId = OtherActor },
            "duplicate" => inventory with { Items = [Sit(), Sit()] },
            _ => inventory with { ExpiresAtUtc = Now }
        };
        ExpectConnectionLoad(fixture, Connection("Connected"), inventory: inventory);
        var page = ConnectionPage(fixture);
        Assert.Empty(page.FindAll("#purview-sensitive-information-type"));
        Assert.Contains("Refresh required", page.Markup);
        Assert.DoesNotContain("catalog is ready for policy review", page.Markup);
        if (fault != "expired")
            Assert.Empty(page.FindAll("[data-testid='tenant-inventory-count']"));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Collection_inventory_refresh_preserves_the_prior_name_without_silently_reselecting()
    {
        using var fixture = CoreUiData.Create();
        ExpectCapabilities(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(Connection("Connected"))));
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewKnowYourDataAsync),
            CoreUiData.Resource(new PurviewKnowYourDataResponse(null)));
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewSensitiveInformationTypesAsync), CoreUiData.Resource(Inventory()));
        ExpectConfig(fixture);
        fixture.Services.GetRequiredService<NavigationManager>().NavigateTo("/settings/collection");
        var page = fixture.Render<Settings>(parameters => parameters.Add(item => item.TaskName, "collection"));
        page.Find("#purview-sensitive-information-type").Change("0");
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewSensitiveInformationTypesAsync), CoreUiData.Resource(Inventory()));
        await AdminUiFixture.ClickAsync(page, "Reload inventory");
        Assert.Contains("Earlier choice: Synthetic classifier", page.Markup);
        Assert.Equal("", page.Find("#purview-sensitive-information-type").GetAttribute("value"));
        fixture.AssertComplete();
    }

    private static FakeTimeProvider Clock(AdminUiFixture fixture) =>
        (FakeTimeProvider)fixture.Services.GetRequiredService<TimeProvider>();

    private static bool ConnectionRefreshDisabled(IRenderedComponent<Settings> page) =>
        page.FindAll("fluent-button")
            .Single(button => button.TextContent.Trim() == "Review connection refresh")
            .HasAttribute("disabled");

    private static IRenderedComponent<Settings> ConnectionPage(AdminUiFixture fixture, bool reopen = false)
    {
        fixture.Services.GetRequiredService<NavigationManager>().NavigateTo(reopen
            ? $"/settings/connection?operation={ReviewId:D}" : "/settings/connection");
        return fixture.Render<Settings>(parameters => parameters.Add(item => item.TaskName, "connection"));
    }

    private static void ExpectCapabilities(AdminUiFixture fixture, bool installed = true) =>
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionCapabilitiesAsync),
            CoreUiData.Resource(new ProtectionCapabilitiesResponse([
                new(ConnectionId, "Purview", installed ? "Installed" : "NotInstalled",
                    new(null, null, null, null, null, null, null, null, null), Now, null, CoreUiData.Version)
            ])));

    private static void ExpectConfig(AdminUiFixture fixture) =>
        fixture.Script.Return(nameof(IGatewayApiClient.GetSystemConfigAsync), CoreUiData.Config());

    private static void ExpectConnectionLoad(AdminUiFixture fixture, PurviewTenantConnectionDto? connection = null,
        bool operation = false, Guid? actor = null, PurviewSensitiveInformationTypeListResponse? inventory = null)
    {
        ExpectCapabilities(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(connection)));
        if (inventory is not null)
            fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewSensitiveInformationTypesAsync), CoreUiData.Resource(inventory));
        if (operation)
            ExpectOperation(fixture, actor);
        ExpectConfig(fixture);
    }

    private static PurviewTenantConnectionDto Connection(string status = "AwaitingAdministrator") => new(
        ConnectionId, AdminUiFixture.Tenant, status, "InteractiveDelegatedAdministrator", null, null,
        InventoryId, Now, CoreUiData.Now.AddMinutes(10).UtcDateTime, Now, null, CoreUiData.Version);

    private static PurviewSensitiveInformationTypeDto Sit() => new(SitId, "Synthetic classifier", "Fixture");
    private static PurviewSensitiveInformationTypeListResponse Inventory() => new(
        InventoryId, AdminUiFixture.Tenant, Now, Now.AddMinutes(5), false, [Sit()]);

    private static ProtectionOperationReviewTicket ExpectConnectionReview(AdminUiFixture fixture,
        string targetType = "PurviewTenantConnection", string scope = "Tenant",
        string expectedRowVersion = "*", Guid? operationId = null)
    {
        var summary = new ProtectionOperationReviewSummaryDto(AdminUiFixture.Tenant, ConnectionAction,
            targetType, AdminUiFixture.Tenant.ToString("D"), null, null, null, null, [], [],
            scope, "Application", "Review is not connection verification.");
        var ticket = new ProtectionOperationReviewTicket(
            new(operationId ?? ReviewId, "synthetic-review-token", Hash,
                Clock(fixture).GetUtcNow().UtcDateTime.AddMinutes(1), summary), expectedRowVersion);
        fixture.Script.Return(nameof(IGatewayApiClient.ReviewPurviewTenantConnectionAsync), CoreUiData.Resource(ticket),
            arguments =>
            {
                var request = Assert.IsType<Gateway.Contracts.Requests.ReviewPurviewTenantConnectionRequest>(arguments[0]);
                Assert.Equal(AdminUiFixture.Tenant, request.TenantId);
                Assert.Equal(expectedRowVersion, request.ExpectedRowVersion);
            });
        return ticket;
    }

    private static void ExpectConfirmation(AdminUiFixture fixture, ProtectionOperationReviewTicket review)
    {
        var ticket = new ProtectionOperationConfirmationTicket(
            new(review.ReviewTokenId, review.ReviewTokenId, "synthetic-confirmation-token",
                Clock(fixture).GetUtcNow().UtcDateTime.AddMinutes(1)), review.Review, review.ExpectedRowVersion);
        fixture.Script.Return(nameof(IGatewayApiClient.ConfirmProtectionOperationReviewAsync), CoreUiData.Resource(ticket),
            arguments => Assert.Same(review, arguments[0]));
    }

    private static async Task<ProtectionOperationReviewTicket> ReviewCompletionAsync(
        AdminUiFixture fixture, IRenderedComponent<Settings> page, bool paste = false)
    {
        if (paste)
            page.Find("#purview-companion-output").Input(Output());
        else
            page.FindComponent<InputFile>().UploadFiles(
                InputFileContent.CreateFromText(Output(), "synthetic-connection.txt"));
        page.WaitForAssertion(() => Assert.Contains("Evidence checked for this tenant", page.Markup));
        var evidence = new PurviewTenantConnectionEvidenceDto(
            AdminUiFixture.Tenant, AdminUiFixture.Actor,
            ["DlpPolicy.ReadWrite", "DlpRule.ReadWrite", "KnowYourData.ReadWrite", "SensitiveInformationTypes.Read"],
            CoreUiData.Now, CoreUiData.Now.AddMinutes(10), [Sit()]);
        var summary = new ProtectionOperationReviewSummaryDto(
            AdminUiFixture.Tenant, "CompletePurviewTenantConnection", "PurviewTenantConnection",
            ConnectionId.ToString("D"), null, null, null, null, [], [], "Tenant", "Application",
            "Evidence submission is not connection verification.", ReviewId, InventoryId,
            PurviewTenantConnectionEvidenceDigest.Compute(ReviewId, InventoryId, evidence));
        var ticket = new ProtectionOperationReviewTicket(
            new(CompletionReviewId, "synthetic-completion-review", Hash, Now.AddMinutes(1), summary),
            CoreUiData.Version);
        fixture.Script.Return(nameof(IGatewayApiClient.ReviewPurviewTenantConnectionCompletionAsync),
            CoreUiData.Resource(ticket), arguments =>
            {
                Assert.Equal(ReviewId, Assert.IsType<Guid>(arguments[0]));
                Assert.Equal(InventoryId, Assert.IsType<Guid>(arguments[1]));
            });
        await AdminUiFixture.ClickAsync(page, "Review companion completion");
        Assert.Single(page.FindComponents<ConfirmPanel>());
        return ticket;
    }

    private static ProtectionAdminOperationDto PendingConnection() => Operation() with
    {
        Status = "Pending", RequiredAction = null
    };

    private static ProtectionAdminOperationDto SubmittedCompletion() => Operation() with
    {
        Id = CompletionReviewId, Type = "CompletePurviewTenantConnection", Status = "Submitted",
        ReadbackReferenceId = ReviewId, RequiredAction = null
    };

    private static void ExpectPendingConnectionReadback(AdminUiFixture fixture)
    {
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
            CoreUiData.Resource(new ProtectionAdminOperationResponse(PendingConnection())),
            arguments => Assert.Equal(ReviewId, Assert.IsType<Guid>(arguments[0])));
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(Connection("PendingVerification"))));
    }

    private static void ExpectConfirmedStart(AdminUiFixture fixture, ProtectionOperationReviewTicket review)
    {
        ExpectConfirmation(fixture, review);
        fixture.Script.Return(nameof(IGatewayApiClient.StartPurviewTenantConnectionOperationAsync),
            CoreUiData.Resource(new ProtectionOperationAcceptedResponse(ReviewId, "AwaitingAdministrator", ReviewId, Launch())));
        ExpectOperation(fixture);
        fixture.Script.Return(nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync),
            CoreUiData.Resource(new PurviewTenantConnectionResponse(Connection())));
    }

    private static void ExpectOperation(AdminUiFixture fixture, Guid? actor = null) =>
        fixture.Script.Return(nameof(IGatewayApiClient.GetProtectionAdminOperationAsync),
            CoreUiData.Resource(new ProtectionAdminOperationResponse(Operation(actor), actor is null ? Launch() : null)),
            arguments => Assert.Equal(ReviewId, Assert.IsType<Guid>(arguments[0])));

    private static ProtectionAdminOperationDto Operation(Guid? actor = null) => new(
        ReviewId, 1, ConnectionAction, "AwaitingAdministrator", AdminUiFixture.Tenant,
        (actor ?? AdminUiFixture.Actor).ToString("D"), "PurviewTenantConnection", ConnectionId.ToString("D"),
        Hash, ReviewId, "*", "Retryable", 0, 3, null, false, false, ReviewId, null, null,
        "CompletePurviewTenantConnection", [], Now, Now, null, Now, [], CoreUiData.Version);

    private static PurviewCompanionLaunchDto Launch(
        Guid? operationId = null, Guid? inventoryId = null, DateTimeOffset? expiresAtUtc = null)
    {
        var id = operationId ?? ReviewId;
        var generation = inventoryId ?? InventoryId;
        var expiry = expiresAtUtc ?? CoreUiData.Now.AddMinutes(10);
        return new(id, generation, expiry,
            "Automation/Connect-PurviewTenant.ps1",
            ["-NoLogo", "-NoProfile", "-File", "Automation/Connect-PurviewTenant.ps1",
                "-OperationId", id.ToString("D"), "-TenantId", AdminUiFixture.Tenant.ToString("D"),
                "-AdministratorObjectId", AdminUiFixture.Actor.ToString("D"),
                "-InventoryGenerationId", generation.ToString("D"), "-ExpiresAtUtc", expiry.ToString("O")]);
    }

    private static string Output(string? mismatch = null, int itemCount = 1)
    {
        var items = itemCount == 1 ? new[] { Sit() } :
            Enumerable.Range(1, itemCount).Select(index => Sit() with
            {
                Id = Guid.Parse($"77777777-7777-4777-8777-{index:D12}"),
                ExactName = $"Synthetic classifier {index:D4} " + new string('n', 100)
            }).ToArray();
        var payload = JsonSerializer.SerializeToUtf8Bytes(new
        {
            operationId = mismatch == "operation" ? OtherActor : ReviewId,
            tenantId = mismatch == "tenant" ? OtherActor : AdminUiFixture.Tenant,
            administratorObjectId = mismatch == "actor" ? OtherActor : AdminUiFixture.Actor,
            inventoryGenerationId = mismatch == "generation" ? OtherActor : InventoryId,
            observedAtUtc = mismatch == "future" ? CoreUiData.Now.AddMinutes(1) : CoreUiData.Now,
            inventoryExpiresAtUtc = mismatch == "expiry" ? CoreUiData.Now : CoreUiData.Now.AddMinutes(10),
            authorizedCapabilities = new[] { "DlpPolicy.ReadWrite", "DlpRule.ReadWrite", "KnowYourData.ReadWrite", "SensitiveInformationTypes.Read" },
            sensitiveInformationTypes = mismatch == "duplicate" ? new[] { Sit(), Sit() } : items
        }, new JsonSerializerOptions(JsonSerializerDefaults.Web));
        return "A365GW_CONNECTION_RESULT:" + Convert.ToBase64String(payload);
    }
}
