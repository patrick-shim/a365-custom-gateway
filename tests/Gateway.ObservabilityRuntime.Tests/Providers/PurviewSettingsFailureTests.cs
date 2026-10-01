using System.Net;
using System.Text.Json;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;
using Gateway.ObservabilityRuntime.Tests.Fixtures;
using Gateway.Provisioning.Worker;
using Gateway.Purview;
using Gateway.Purview.Executor;
using Microsoft.Extensions.Options;

namespace Gateway.ObservabilityRuntime.Tests.Providers;

public sealed class PurviewSettingsFailureTests
{
    private const string ExpiryMarker = "A365GW_VERIFIER_ERROR:InvalidData:Other:00000000:InventoryExpired";
    private const string Endpoint = "https://settings-fixture.azurewebsites.net/";
    private static readonly Guid OperationId = FixtureIds.Agent;
    private static readonly TimeProvider Clock = new FixtureClock();
    private static PurviewExecutorBinding Binding => new(
        FixtureIds.Registry, FixtureIds.Tenant, "sha256:" + new string('a', 64),
        "sha256:" + new string('b', 64), "sha256:" + new string('c', 64),
        FixtureIds.Blueprint, FixtureIds.Principal,
        $"/subscriptions/{FixtureIds.Tenant:D}/resourceGroups/fixture/providers/Microsoft.KeyVault/vaults/fixture-vault",
        "fixture-certificate", "https://fixture-vault.vault.azure.net/secrets/fixture-certificate",
        FixtureIds.Agent, FixtureIds.Actor, FixtureIds.Child, FixtureIds.Registry,
        Guid.Parse("88888888-8888-4888-8888-888888888888"),
        Guid.Parse("99999999-9999-4999-8999-999999999999"), FixtureIds.Actor);

    [Theory]
    [InlineData(ExpiryMarker, true)]
    [InlineData("A365GW_VERIFIER_STAGE:6\r\n" + ExpiryMarker + "\r\n", true)]
    [InlineData("InventoryExpired", false)]
    [InlineData("untrusted text " + ExpiryMarker, false)]
    [InlineData(ExpiryMarker + "Extra", false)]
    [InlineData("A365GW_VERIFIER_ERROR:InvalidData:Other:00000000:inventoryexpired", false)]
    public void Native_read_classification_accepts_only_the_exact_bounded_marker(string text, bool expired) =>
        Assert.Equal(expired ? "PURVIEW_INVENTORY_STALE" : "PURVIEW_SETTINGS_READ_FAILED",
            PowerShellPurviewSettingsAutomation.ClassifyChildReadFailure(text));

    [Fact]
    public void Expiry_remains_visible_in_safe_provider_diagnostics()
    {
        var diagnostics = new PurviewSettingsFailureDiagnostics(Clock);
        diagnostics.Record(OperationId, "ReadDlpProfile", "ChildCompletion",
            new InvalidOperationException(), 1, "A365GW_VERIFIER_STAGE:6\n" + ExpiryMarker);
        var failure = Assert.IsType<PurviewSettingsFailure>(diagnostics.Read());
        Assert.Equal(OperationId, failure.OperationId);
        Assert.Equal(6, failure.ProviderStage);
        Assert.Equal("InventoryExpired", Assert.Single(failure.ProviderErrors).Code);
    }

    [Theory]
    [InlineData(PurviewExecutorCommand.ReadDlpProfile, "PURVIEW_INVENTORY_STALE", false, "Rejected")]
    [InlineData(PurviewExecutorCommand.ReadKnowYourData, "PURVIEW_INVENTORY_STALE", false, "Rejected")]
    [InlineData(PurviewExecutorCommand.ReadDlpProfile, "PURVIEW_SETTINGS_READ_TIMEOUT", true, "RetryableRead")]
    [InlineData(PurviewExecutorCommand.ReadKnowYourData, "PURVIEW_SETTINGS_READ_TIMEOUT", true, "RetryableRead")]
    [InlineData(PurviewExecutorCommand.ReadDlpProfile, "PURVIEW_SETTINGS_READ_TIMEOUT", false, "Unavailable")]
    [InlineData(PurviewExecutorCommand.ReadDlpProfile, "UNRECOGNIZED_PROVIDER_DETAIL", true, "Unavailable")]
    public async Task Dispatcher_retains_only_allowlisted_read_failure_details(
        PurviewExecutorCommand command, string code, bool transient, string status)
    {
        var automation = new FailureAutomation(code, transient);
        var store = new ClaimStore();
        var dispatcher = Dispatcher(automation, store);
        var result = await dispatcher.ExecuteAsync(Request(command), CancellationToken.None);
        Assert.Equal(status, result.Status);
        Assert.Equal(status == "Unavailable" ? "PURVIEW_EXECUTOR_PROVIDER_UNAVAILABLE" : code, result.FailureCode);
        Assert.Null(result.Value);
        Assert.Equal(1, automation.Reads);
        Assert.Equal(0, automation.Mutations);
        Assert.Empty(store.Claims);
    }

    [Theory]
    [InlineData(PurviewExecutorCommand.CreateKnowYourData)]
    [InlineData(PurviewExecutorCommand.CreateDlpPolicy)]
    [InlineData(PurviewExecutorCommand.CreateDlpRule)]
    public async Task Mutation_failures_remain_unknown_and_started_claims_are_not_replayed(PurviewExecutorCommand command)
    {
        var automation = new FailureAutomation("PURVIEW_INVENTORY_STALE", false);
        var store = new ClaimStore();
        var dispatcher = Dispatcher(automation, store);
        var request = Request(command);
        var first = await dispatcher.ExecuteAsync(request, CancellationToken.None);
        var second = await dispatcher.ExecuteAsync(request, CancellationToken.None);
        Assert.Equal("OutcomeUnknown", first.Status);
        Assert.Equal("OutcomeUnknown", second.Status);
        Assert.Equal("PURVIEW_EXECUTOR_MUTATION_UNKNOWN", second.FailureCode);
        Assert.Equal(1, automation.Mutations);
        Assert.Equal(0, automation.Reads);
        Assert.Equal(ExecutorClaimState.Started, Assert.Single(store.Claims).Value.State);
    }

    [Theory]
    [InlineData(PurviewExecutorCommand.ReadDlpProfile, "Rejected", "PURVIEW_INVENTORY_STALE", false)]
    [InlineData(PurviewExecutorCommand.ReadKnowYourData, "Rejected", "PURVIEW_INVENTORY_STALE", false)]
    [InlineData(PurviewExecutorCommand.ReadDlpProfile, "RetryableRead", "PURVIEW_SETTINGS_READ_TIMEOUT", true)]
    [InlineData(PurviewExecutorCommand.ReadKnowYourData, "RetryableRead", "PURVIEW_SETTINGS_READ_TIMEOUT", true)]
    public async Task Bound_client_preserves_known_read_failures_without_resending(
        PurviewExecutorCommand command, string status, string code, bool transient)
    {
        using var fixture = new ClientFixture(new(Binding, OperationId, command, status, FailureCode: code));
        var error = await Assert.ThrowsAsync<PurviewPolicyException>(() =>
            fixture.Client.ReadAsync<JsonElement, JsonElement>(command, OperationId, FixtureIds.Tenant,
                Request(command).Input, CancellationToken.None));
        Assert.Equal(code, error.FailureCode);
        Assert.Equal(transient, error.IsTransient);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("Completed", "PURVIEW_INVENTORY_STALE", false)]
    [InlineData("Rejected", "PURVIEW_INVENTORY_STALE", true)]
    [InlineData("RetryableRead", "PURVIEW_INVENTORY_STALE", false)]
    [InlineData("Rejected", "PURVIEW_SETTINGS_READ_TIMEOUT", false)]
    [InlineData("Unavailable", "PURVIEW_SETTINGS_READ_TIMEOUT", false)]
    [InlineData("Rejected", "UNRECOGNIZED_PROVIDER_DETAIL", false)]
    public async Task Inconsistent_or_unrecognized_failure_replies_stay_generic(string status, string code, bool hasValue)
    {
        using var fixture = new ClientFixture(new(Binding, OperationId, PurviewExecutorCommand.ReadDlpProfile,
            status, hasValue ? JsonSerializer.SerializeToElement(new { }) : null, code));
        var error = await Assert.ThrowsAsync<PurviewPolicyException>(() =>
            fixture.Client.ReadAsync<object, JsonElement>(PurviewExecutorCommand.ReadDlpProfile,
                OperationId, FixtureIds.Tenant, new { }, CancellationToken.None));
        Assert.Equal("PURVIEW_EXECUTOR_READ_UNAVAILABLE", error.FailureCode);
        Assert.False(error.IsTransient);
        fixture.AssertComplete();
    }

    [Fact]
    public async Task Failure_codes_do_not_override_the_exact_response_binding()
    {
        using var fixture = new ClientFixture(new(Binding, FixtureIds.Child, PurviewExecutorCommand.ReadDlpProfile,
            "Rejected", FailureCode: "PURVIEW_INVENTORY_STALE"));
        var error = await Assert.ThrowsAsync<PurviewPolicyException>(() =>
            fixture.Client.ReadAsync<object, JsonElement>(PurviewExecutorCommand.ReadDlpProfile,
                OperationId, FixtureIds.Tenant, new { }, CancellationToken.None));
        Assert.Equal("PURVIEW_EXECUTOR_RESPONSE_BINDING_MISMATCH", error.FailureCode);
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData("Rejected", "PURVIEW_INVENTORY_STALE")]
    [InlineData("RetryableRead", "PURVIEW_SETTINGS_READ_TIMEOUT")]
    public async Task Client_never_treats_a_mutation_reply_as_a_retryable_read(string status, string code)
    {
        using var fixture = new ClientFixture(new(Binding, OperationId, PurviewExecutorCommand.CreateDlpPolicy,
            status, FailureCode: code));
        await Assert.ThrowsAsync<PurviewMutationOutcomeUnknownException>(() =>
            fixture.Client.MutateAsync(PurviewExecutorCommand.CreateDlpPolicy, OperationId,
                FixtureIds.Tenant, new { }, CancellationToken.None));
        fixture.AssertComplete();
    }

    [Theory]
    [InlineData(PurviewProviderObjectState.Absent)]
    [InlineData(PurviewProviderObjectState.PolicyOnlyExact)]
    [InlineData(PurviewProviderObjectState.Mismatch)]
    [InlineData(PurviewProviderObjectState.Unknown)]
    public async Task Reconciliation_cannot_create_or_update_objects_when_readback_is_incomplete(PurviewProviderObjectState state)
    {
        var automation = new FailureAutomation("UNEXPECTED_MUTATION", false, state);
        var intent = DlpIntent() with { InventoryExpiresAtUtc = DateTimeOffset.UtcNow.AddMinutes(10) };
        var error = await Assert.ThrowsAsync<PurviewPolicyException>(() =>
            new PurviewSettingsProvider(automation).ReconcileDlpProfileAsync(intent, CancellationToken.None));
        Assert.Equal("PURVIEW_DLP_READBACK_MISSING", error.FailureCode);
        Assert.Equal(1, automation.Reads);
        Assert.Equal(0, automation.Mutations);
    }

    private static ExecutorDispatcher Dispatcher(FailureAutomation automation, ClaimStore store) =>
        new(Options.Create(new ExecutorHostOptions { Binding = Binding }), new DeniedConnection(),
            automation, new ExecutorOperationJournal(store, Clock, new PurviewProcessSafety()), Clock);

    private static PurviewExecutorRequest Request(PurviewExecutorCommand command)
    {
        object intent = command is PurviewExecutorCommand.ReadKnowYourData or PurviewExecutorCommand.CreateKnowYourData
            ? new PurviewKnowYourDataIntent(OperationId, FixtureIds.Tenant, FixtureIds.Child, Clock.GetUtcNow().AddMinutes(10),
                FixtureIds.Actor, "Synthetic type", "Fixture", "Synthetic collection", PurviewMode.AuditOnly,
                [PurviewPolicyActivity.UploadText], false, null)
            : DlpIntent();
        return new(Binding, OperationId, command, Clock.GetUtcNow().AddMinutes(4),
            JsonSerializer.SerializeToElement(intent, intent.GetType(), PurviewExecutorJson.Options));
    }

    private static PurviewDlpProfileIntent DlpIntent() =>
        new(OperationId, FixtureIds.Tenant, FixtureIds.Child, Clock.GetUtcNow().AddMinutes(10),
            FixtureIds.Actor, "Synthetic type", "Fixture", FixtureIds.Blueprint, "Synthetic policy",
            "Synthetic rule", PurviewMode.Enforce, [PurviewPolicyActivity.UploadText],
            [new(PurviewPolicyActivity.UploadText, PurviewDlpAction.Block)], null, null,
            SensitiveInformationTypes: [new(FixtureIds.Actor, "Synthetic type", "Fixture", 0, 1, -1, 75, 100)]);

    private sealed class FixtureClock : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => new(FixtureIds.Timestamp);
    }

    private sealed class DeniedConnection : IPurviewConnectionVerificationProvider
    {
        public Task<PurviewConnectionVerificationEvidence> VerifyAsync(
            PurviewConnectionVerificationRequest request, CancellationToken ct) =>
            throw new UnexpectedFixtureCallException("Connection verification was not requested.");
    }

    private sealed class FailureAutomation(string code, bool transient, PurviewProviderObjectState? state = null) : IPurviewSettingsAutomation
    {
        public int Reads { get; private set; }
        public int Mutations { get; private set; }
        private Task<T> Read<T>()
        {
            Reads++;
            return Task.FromException<T>(new PurviewPolicyException(code, "Synthetic bounded failure.", transient));
        }
        private Task Mutate()
        {
            Mutations++;
            return Task.FromException(new PurviewPolicyException(code, "Synthetic bounded failure.", transient));
        }
        public Task<PurviewProviderReadback<PurviewKnowYourDataReadback>> ReadKnowYourDataAsync(
            PurviewKnowYourDataIntent intent, CancellationToken ct) => Read<PurviewProviderReadback<PurviewKnowYourDataReadback>>();
        public Task<PurviewProviderReadback<PurviewDlpProfileReadback>> ReadDlpProfileAsync(
            PurviewDlpProfileIntent intent, CancellationToken ct)
        {
            if (state is not { } resultState)
                return Read<PurviewProviderReadback<PurviewDlpProfileReadback>>();
            Reads++;
            return Task.FromResult(new PurviewProviderReadback<PurviewDlpProfileReadback>(resultState, null));
        }
        public Task CreateKnowYourDataAsync(PurviewKnowYourDataIntent intent, CancellationToken ct) => Mutate();
        public Task CreateDlpPolicyAsync(PurviewDlpProfileIntent intent, CancellationToken ct) => Mutate();
        public Task CreateDlpRuleAsync(PurviewDlpProfileIntent intent, CancellationToken ct) => Mutate();
    }

    private sealed class ClaimStore : IExecutorClaimStore
    {
        public Dictionary<string, ExecutorClaim> Claims { get; } = new(StringComparer.Ordinal);
        public Task<bool> TryCreateAsync(string key, ExecutorClaim value, CancellationToken ct) =>
            Task.FromResult(Claims.TryAdd(key, value));
        public Task<ExecutorClaim?> ReadAsync(string key, CancellationToken ct) =>
            Task.FromResult(Claims.GetValueOrDefault(key));
        public Task CompleteAsync(string key, ExecutorClaim started, CancellationToken ct) =>
            throw new UnexpectedFixtureCallException("A failed mutation cannot complete its claim.");
    }

    private sealed class ClientFixture : IDisposable
    {
        private readonly ScriptedTransport transport = new();
        private readonly FixtureCredential credential = new();
        public PurviewExecutorClient Client { get; }

        public ClientFixture(PurviewExecutorReply reply)
        {
            credential.Calls.Expect(request =>
            {
                Assert.Equal([$"api://{Binding.ExecutorApplicationId:D}/.default"], request.Scopes);
                return FixtureIds.Token;
            });
            transport.Expect(HttpMethod.Post, Endpoint + "executor/v1/execute", HttpStatusCode.OK,
                JsonSerializer.Serialize(reply, PurviewExecutorJson.Options));
            Client = new(new ClosedHttpClientFactory(PurviewExecutorClient.HttpClientName, transport),
                Options.Create(new PurviewExecutorOptions { Enabled = true, Endpoint = Endpoint, Binding = Binding }),
                Options.Create(new PurviewOptions
                {
                    PolicyProvisioningApplicationId = Binding.AutomationApplicationId.ToString("D"),
                    PolicyProvisioningCertificateSecretUri = Binding.CertificateSecretUri
                }), credential);
        }
        public void AssertComplete()
        {
            transport.AssertComplete();
            credential.Calls.AssertComplete();
            Assert.Single(transport.Requests);
        }
        public void Dispose() => transport.Dispose();
    }
}
