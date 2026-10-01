using System.Text;
using Bunit;
using Gateway.AdminUi.Components.Pages;
using Gateway.AdminUi.Components.Shared;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.AdminUi.Tests.Fixtures;
using Gateway.Contracts.Responses;
using Microsoft.AspNetCore.Components;
using Microsoft.AspNetCore.Components.Forms;
using Microsoft.Extensions.DependencyInjection;

namespace Gateway.AdminUi.Tests.Components;

public sealed partial class M4SettingsJourneyTests
{
    [Fact]
    public void First_run_explains_exact_file_trust_before_execution_and_paste_without_a_file()
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        var commands = page.FindComponents<CopyableValue>();
        var trust = commands.Single(component => component.Instance.Label == "Trust this downloaded file");
        Assert.Equal(@"Unblock-File -LiteralPath '.\Connect-PurviewTenant.ps1' -ErrorAction Stop", trust.Instance.Value);
        Assert.Contains("A blocked script cannot perform this step itself", page.Markup);
        Assert.Contains("No output is normal", page.Markup);
        Assert.Contains("request an approved signed copy", page.Markup);
        Assert.Contains("choose Open in Terminal", page.Markup);
        Assert.Contains("pwsh -NoLogo -NoProfile", page.Markup);
        Assert.DoesNotContain("Set-ExecutionPolicy", page.Markup);
        Assert.DoesNotContain("-ExecutionPolicy", page.Markup);
        Assert.True(page.Markup.IndexOf("Trust this downloaded file", StringComparison.Ordinal) <
            page.Markup.IndexOf("Run the connection", StringComparison.Ordinal));
        Assert.Contains("No text file is required", page.Markup);
        Assert.Contains("Or upload a saved result (optional)", page.Markup);
        Assert.False(page.Find(".companion-upload").HasAttribute("open"));
        Assert.Equal("false", page.Find("#purview-companion-output").GetAttribute("aria-invalid"));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("tenant")]
    [InlineData("actor")]
    [InlineData("operation")]
    [InlineData("generation")]
    [InlineData("future")]
    [InlineData("expiry")]
    [InlineData("duplicate")]
    public void Pasted_mismatched_result_cannot_reach_review(string mismatch)
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        page.Find("#purview-companion-output").Input(Output(mismatch));
        Assert.Contains("not the single fresh result", page.Markup);
        Assert.True(CompletionReviewDisabled(page));
        Assert.Equal("true", page.Find("#purview-companion-output").GetAttribute("aria-invalid"));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("console")]
    [InlineData("duplicate-line")]
    [InlineData("json")]
    [InlineData("repair")]
    public void Pasting_commands_extra_results_or_repair_output_explains_what_to_copy(string kind)
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        var text = kind switch
        {
            "console" => "PS C:\\Synthetic> pwsh .\\Connect-PurviewTenant.ps1\n" + Output(),
            "duplicate-line" => Output() + "\n" + Output(),
            "json" => "{\"operationId\":\"" + ReviewId + "\"}",
            _ => "PURVIEW_REFERENCE_REGISTRATION {\"status\":\"ExactReferenceVerified\"}"
        };
        page.Find("#purview-companion-output").Input(text);
        Assert.Contains("Paste only the complete line beginning A365GW_CONNECTION_RESULT:", page.Markup);
        Assert.Contains("no new sign-in is needed just to copy it", page.Markup);
        Assert.True(CompletionReviewDisabled(page));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void Pasted_and_uploaded_results_share_whitespace_handling_and_validation(bool upload)
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        var output = " \r\n" + Output() + "\r\n ";
        if (upload)
            page.FindComponent<InputFile>().UploadFiles(InputFileContent.CreateFromText(output, "synthetic.txt"));
        else
            page.Find("#purview-companion-output").Input(output);
        page.WaitForAssertion(() => Assert.Contains("Evidence checked for this tenant", page.Markup));
        Assert.False(CompletionReviewDisabled(page));
        Assert.DoesNotContain("Connection verified", page.Markup);
        fixture.AssertComplete();
    }

    [Fact]
    public void Realistic_catalog_paste_exceeds_default_circuit_size_but_remains_within_input_limits()
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        var output = Output(itemCount: 354);
        Assert.InRange(Encoding.UTF8.GetByteCount(output), 32 * 1024 + 1, PurviewCompanionInputLimits.MaximumOutputBytes);
        page.Find("#purview-companion-output").Input(output);
        Assert.Contains("354 current sensitive information types", page.Markup);
        Assert.False(CompletionReviewDisabled(page));
        fixture.AssertComplete();
    }

    [Fact]
    public void Oversized_paste_is_rejected_on_the_server_even_if_browser_maxlength_is_bypassed()
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        page.Find("#purview-companion-output").Input(new string('A', PurviewCompanionInputLimits.MaximumOutputBytes + 1));
        Assert.Contains("larger than the supported 512 KB limit", page.Markup);
        Assert.True(CompletionReviewDisabled(page));
        fixture.AssertComplete();
    }

    [Fact]
    public void Pasted_invalid_unicode_has_an_explicit_error()
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        page.Find("#purview-companion-output").Input("A365GW_CONNECTION_RESULT:\ud800");
        Assert.Contains("This result contains invalid text", page.Markup);
        Assert.True(CompletionReviewDisabled(page));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("")]
    [InlineData(" ")]
    [InlineData("edited")]
    public async Task Editing_or_clearing_pasted_evidence_discards_its_completion_approval(string replacement)
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        var review = await ReviewCompletionAsync(fixture, page, paste: true);
        await page.InvokeAsync(() => page.Find("#purview-companion-output")
            .InputAsync(new ChangeEventArgs { Value = replacement }));
        Assert.False(review.IsAvailable);
        Assert.Empty(page.FindComponents<ConfirmPanel>());
        Assert.True(CompletionReviewDisabled(page));
        Assert.DoesNotContain(nameof(IGatewayApiClient.CompletePurviewTenantConnectionOperationAsync), fixture.Script.Calls);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Pasted_result_completes_once_under_the_original_operation_without_a_file()
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        var review = await ReviewCompletionAsync(fixture, page, paste: true);
        ExpectConfirmation(fixture, review);
        fixture.Script.Return(nameof(IGatewayApiClient.CompletePurviewTenantConnectionOperationAsync),
            CoreUiData.Resource(new ProtectionOperationAcceptedResponse(ReviewId, "Pending", ReviewId)));
        ExpectPendingConnectionReadback(fixture);
        await AdminUiFixture.ClickAsync(page, "Submit for verification");
        Assert.Contains("Companion result received. Checking Gateway access.", page.Markup);
        Assert.Empty(page.FindAll("#purview-companion-output, #purview-companion-evidence"));
        Assert.DoesNotContain(Output(), page.Markup);
        Assert.Equal(1, fixture.Script.Calls.Count(call =>
            call == nameof(IGatewayApiClient.CompletePurviewTenantConnectionOperationAsync)));
        fixture.AssertComplete();
    }

    [Fact]
    public void Choosing_an_optional_file_replaces_and_clears_the_pasted_result()
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        page.Find("#purview-companion-output").Input(Output());
        Assert.False(CompletionReviewDisabled(page));
        page.FindComponent<InputFile>().UploadFiles(InputFileContent.CreateFromText(Output("actor"), "synthetic.txt"));
        page.WaitForAssertion(() => Assert.Contains("not the single fresh result", page.Markup));
        Assert.Equal("", page.Find("#purview-companion-output").GetAttribute("value"));
        Assert.True(CompletionReviewDisabled(page));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task A_late_optional_file_read_cannot_replace_newer_pasted_evidence()
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        var file = new DelayedCompanionFile(Output("actor"));
        var input = page.FindComponent<InputFile>().Instance;
        var reading = page.InvokeAsync(() => input.OnChange.InvokeAsync(new InputFileChangeEventArgs([file])));
        await file.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        page.Find("#purview-companion-output").Input(Output());
        file.Release.SetResult();
        await reading;
        Assert.Contains("Evidence checked for this tenant", page.Markup);
        Assert.DoesNotContain("not the single fresh result", page.Markup);
        Assert.False(CompletionReviewDisabled(page));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("cancelled")]
    [InlineData("timeout")]
    [InlineData("io")]
    public async Task Interrupted_optional_file_reads_offer_paste_without_claiming_success(string kind)
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        Exception failure = kind switch
        {
            "cancelled" => new OperationCanceledException("Synthetic file interruption."),
            "timeout" => new TimeoutException("Synthetic file timeout."),
            _ => new IOException("Synthetic file read failure.")
        };
        var file = new DelayedCompanionFile(Output(), failure);
        var input = page.FindComponent<InputFile>().Instance;
        var reading = page.InvokeAsync(() => input.OnChange.InvokeAsync(new InputFileChangeEventArgs([file])));
        await file.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        file.Release.SetResult();
        await reading;
        Assert.Contains("Paste the existing A365GW_CONNECTION_RESULT: line into the box instead", page.Markup);
        Assert.DoesNotContain("Evidence checked for this tenant", page.Markup);
        Assert.True(CompletionReviewDisabled(page));
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Leaving_the_retained_connection_clears_the_pasted_result()
    {
        using var fixture = CoreUiData.Create();
        ExpectConnectionLoad(fixture, Connection(), operation: true);
        var page = ConnectionPage(fixture, reopen: true);
        page.Find("#purview-companion-output").Input(Output());
        ExpectConnectionLoad(fixture);
        var navigation = fixture.Services.GetRequiredService<NavigationManager>();
        await page.InvokeAsync(() => navigation.NavigateTo("/settings/connection"));
        Assert.Empty(page.FindAll("#purview-companion-output"));
        Assert.DoesNotContain(Output(), page.Markup);
        fixture.AssertComplete();
    }

    private static bool CompletionReviewDisabled(IRenderedComponent<Settings> page) =>
        page.FindAll("fluent-button").Single(button =>
            button.TextContent.Trim() == "Review companion completion").HasAttribute("disabled");

    private sealed class DelayedCompanionFile(string output, Exception? readFailure = null) : IBrowserFile
    {
        private readonly byte[] bytes = Encoding.UTF8.GetBytes(output);
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public string Name => "synthetic-delayed.txt";
        public DateTimeOffset LastModified => CoreUiData.Now;
        public long Size => bytes.Length;
        public string ContentType => "text/plain";

        public Stream OpenReadStream(long maxAllowedSize = 512000, CancellationToken cancellationToken = default)
        {
            if (Size > maxAllowedSize) throw new IOException("Synthetic size limit.");
            return new DelayedCompanionStream(bytes, Started, Release, readFailure);
        }
    }

    private sealed class DelayedCompanionStream(byte[] bytes, TaskCompletionSource started,
        TaskCompletionSource release, Exception? readFailure)
        : MemoryStream(bytes, writable: false)
    {
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            started.TrySetResult();
            await release.Task.WaitAsync(cancellationToken);
            if (readFailure is not null) throw readFailure;
            return await base.ReadAsync(buffer, cancellationToken);
        }
    }
}
