using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Azure.Core;
using Gateway.Domain.Models;
using Gateway.Domain.Enums;
using Gateway.Domain.ValueObjects;
using Gateway.Purview;
using Gateway.Provisioning.Worker;
using Gateway.Purview.Executor;
using Microsoft.Extensions.Options;

namespace Gateway.ObservabilityRuntime.Tests.PurviewExecutor;

public sealed class ExecutorTransportTests
{
    [Fact]
    public async Task ExactReply_IsAccepted_AndTokenIsScopedToExecutor()
    {
        using var fixture = new Fixture();
        Assert.True((await fixture.ReadAsync()).Ready);
        Assert.Equal($"api://{fixture.Binding.ExecutorApplicationId:D}/.default", fixture.Credential.Scope);
        Assert.Equal(1, fixture.Handler.Calls);
    }

    [Theory]
    [InlineData("binding")]
    [InlineData("operation")]
    [InlineData("command")]
    [InlineData("failure")]
    [InlineData("unknown")]
    public async Task UnboundOrUnverifiedReply_IsRejected(string change)
    {
        using var fixture = new Fixture();
        fixture.Handler.Change = reply => change switch
        {
            "binding" => reply with { Binding = reply.Binding with { PackageDigest = "sha256:" + new string('b', 64) } },
            "operation" => reply with { OperationId = Guid.NewGuid() },
            "command" => reply with { Command = PurviewExecutorCommand.ReadKnowYourData },
            "failure" => reply with { FailureCode = "UNVERIFIED" },
            _ => reply with { Status = "OutcomeUnknown" }
        };
        await Assert.ThrowsAsync<PurviewPolicyException>(fixture.ReadAsync);
        Assert.Equal(1, fixture.Handler.Calls);
    }

    [Theory]
    [InlineData(302)]
    [InlineData(401)]
    [InlineData(503)]
    public async Task MutationHttpFailure_IsUnknown_AndNeverRetried(int status)
    {
        using var fixture = new Fixture();
        fixture.Handler.Status = (HttpStatusCode)status;
        await Assert.ThrowsAsync<PurviewMutationOutcomeUnknownException>(fixture.MutateAsync);
        Assert.Equal(1, fixture.Handler.Calls);
    }

    [Fact]
    public async Task LostMutationResponse_IsUnknown_AndNeverRetried()
    {
        using var fixture = new Fixture();
        fixture.Handler.ThrowAfterDispatch = true;
        await Assert.ThrowsAsync<PurviewMutationOutcomeUnknownException>(fixture.MutateAsync);
        Assert.Equal(1, fixture.Handler.Calls);
    }

    [Fact]
    public async Task LostMutationResponseStream_IsUnknown_AndNeverRetried()
    {
        using var fixture = new Fixture();
        fixture.Handler.FailResponseStream = true;
        await Assert.ThrowsAsync<PurviewMutationOutcomeUnknownException>(fixture.MutateAsync);
        Assert.Equal(1, fixture.Handler.Calls);
    }

    [Fact]
    public async Task ProviderRecoversLostMutationStream_WithFreshExactReadback()
    {
        using var fixture = new Fixture();
        var intent = new PurviewKnowYourDataIntent(fixture.OperationId, fixture.Binding.TenantId,
            Guid.NewGuid(), DateTimeOffset.UtcNow.AddMinutes(10), Guid.NewGuid(),
            "Credit Card Number", "Microsoft", "Offline KYD", PurviewMode.Enforce,
            [PurviewPolicyActivity.UploadText], true, null);
        var commands = new List<PurviewExecutorCommand>();
        fixture.Handler.Response = envelope =>
        {
            commands.Add(envelope.Command);
            if (envelope.Command == PurviewExecutorCommand.CreateKnowYourData)
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new BrokenResponseStream()) };
            var value = commands.Count == 1
                ? PurviewProviderReadback<PurviewKnowYourDataReadback>.Absent()
                : PurviewProviderReadback.Exact(new PurviewKnowYourDataReadback(
                    "offline-provider-id", intent.TenantId, PurviewPolicyLocationContract.EnterpriseAiAppsGroupId,
                    PurviewPolicyScopeType.Group, PurviewEnforcementPlane.Application,
                    intent.SensitiveInformationTypeId, intent.SensitiveInformationTypeName,
                    intent.SensitiveInformationTypePublisher, intent.Mode, intent.Activities,
                    intent.IngestionEnabled, DateTimeOffset.UtcNow));
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = JsonContent.Create(new PurviewExecutorReply(envelope.Binding, envelope.OperationId,
                    envelope.Command, "Completed", JsonSerializer.SerializeToElement(value, PurviewExecutorJson.Options)),
                    options: PurviewExecutorJson.Options)
            };
        };
        var provider = new PurviewSettingsProvider(new RemotePurviewSettingsAutomation(fixture.Client));
        var result = await provider.EnsureKnowYourDataAsync(intent, default);
        Assert.Equal(PurviewSettingsOperationDisposition.RecoveredAfterUnknownOutcome, result.Disposition);
        Assert.Equal("offline-provider-id", result.Readback!.PolicyProviderId);
        Assert.Equal(new[] { PurviewExecutorCommand.ReadKnowYourData,
            PurviewExecutorCommand.CreateKnowYourData, PurviewExecutorCommand.ReadKnowYourData }, commands);
    }

    [Theory]
    [InlineData("http://executor.azurewebsites.net")]
    [InlineData("https://executor.scm.azurewebsites.net")]
    [InlineData("https://unrelated.example")]
    [InlineData("https://executor.azurewebsites.net/path")]
    public async Task InvalidEndpoint_DoesNotAcquireTokenOrDispatch(string endpoint)
    {
        using var fixture = new Fixture();
        fixture.Options.Endpoint = endpoint;
        await Assert.ThrowsAsync<PurviewPolicyException>(fixture.ReadAsync);
        Assert.Null(fixture.Credential.Scope);
        Assert.Equal(0, fixture.Handler.Calls);
    }

    [Fact]
    public async Task ChangedTenant_DoesNotAcquireTokenOrDispatch()
    {
        using var fixture = new Fixture();
        await Assert.ThrowsAsync<PurviewPolicyException>(() => fixture.Client.ReadAsync<object, Readback>(
            PurviewExecutorCommand.VerifyConnection, fixture.OperationId, Guid.NewGuid(), new { }, default));
        Assert.Null(fixture.Credential.Scope);
        Assert.Equal(0, fixture.Handler.Calls);
    }

    [Fact]
    public async Task CompletedMutationCannotReturnReplayableProviderContent()
    {
        using var fixture = new Fixture();
        fixture.Handler.Change = reply => reply with { Value = JsonSerializer.SerializeToElement(new { ready = true }) };
        await Assert.ThrowsAsync<PurviewMutationOutcomeUnknownException>(fixture.MutateAsync);
    }

    [Theory]
    [InlineData("RetryableRead", "PURVIEW_EXECUTOR_CONNECTION_READ_TIMEOUT", true)]
    [InlineData("Unavailable", "PURVIEW_EXECUTOR_CONNECTION_READ_TIMEOUT", false)]
    [InlineData("RetryableRead", "PURVIEW_EXECUTOR_CAPABILITY_MISMATCH", false)]
    public async Task OnlyExactConnectionTimeout_RemainsBoundedRetryableRead(string status, string code, bool transient)
    {
        using var fixture = new Fixture();
        fixture.Handler.Change = reply => reply with { Status = status, FailureCode = code, Value = null };
        var adapter = new RemotePurviewConnectionVerificationProvider(fixture.Client, Options.Create(fixture.Options));
        var failure = await Assert.ThrowsAsync<PurviewConnectionVerificationException>(() =>
            adapter.VerifyAsync(ConnectionRequest(fixture), default));
        Assert.Equal(transient, failure.IsTransient);
        Assert.Equal(1, fixture.Handler.Calls);
    }

    [Theory]
    [InlineData("PURVIEW_CONNECTION_READ_TIMEOUT", true, "RetryableRead")]
    [InlineData("PURVIEW_CONNECTION_READ_TIMEOUT", false, "Unavailable")]
    [InlineData("PURVIEW_CONNECTION_PROVIDER_UNVERIFIED", true, "Unavailable")]
    public async Task DispatcherPreservesOnlyKnownReadTimeout(string code, bool transient, string expectedStatus)
    {
        using var fixture = new Fixture();
        var dispatcher = new ExecutorDispatcher(Options.Create(new ExecutorHostOptions { Binding = fixture.Binding }),
            new FailedConnection(code, transient), null!, null!, TimeProvider.System);
        var result = await dispatcher.ExecuteAsync(new PurviewExecutorRequest(fixture.Binding, fixture.OperationId,
            PurviewExecutorCommand.VerifyConnection, DateTimeOffset.UtcNow.AddMinutes(4),
            JsonSerializer.SerializeToElement(ConnectionRequest(fixture), PurviewExecutorJson.Options)), default);
        Assert.Equal(expectedStatus, result.Status);
        Assert.Null(result.Value);
    }

    private static PurviewConnectionVerificationRequest ConnectionRequest(Fixture fixture) => new(
        fixture.OperationId, fixture.Binding.TenantId, Guid.NewGuid(),
        fixture.Binding.AutomationApplicationId, fixture.Binding.AutomationServicePrincipalObjectId,
        fixture.Binding.KeyVaultResourceId, "test-vault.vault.azure.net", fixture.Binding.CertificateName,
        new Uri(fixture.Binding.CertificateSecretUri));

    private sealed class FailedConnection(string code, bool transient) : IPurviewConnectionVerificationProvider
    {
        public Task<PurviewConnectionVerificationEvidence> VerifyAsync(PurviewConnectionVerificationRequest request,
            CancellationToken ct) => Task.FromException<PurviewConnectionVerificationEvidence>(
                new PurviewConnectionVerificationException(code, transient));
    }

    private sealed record Readback(bool Ready);

    private sealed class Fixture : IDisposable
    {
        public PurviewExecutorBinding Binding { get; } = new(Guid.NewGuid(), Guid.NewGuid(),
            "sha256:" + new string('a', 64), "sha256:" + new string('a', 64), "sha256:" + new string('a', 64),
            Guid.NewGuid(), Guid.NewGuid(),
            $"/subscriptions/{Guid.NewGuid():D}/resourceGroups/offline/providers/Microsoft.KeyVault/vaults/test-vault",
            "automation", "https://test-vault.vault.azure.net/secrets/automation", Guid.NewGuid(), Guid.NewGuid(),
            Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid(), Guid.NewGuid());
        public Guid OperationId { get; } = Guid.NewGuid();
        public OfflineCredential Credential { get; } = new();
        public OfflineHandler Handler { get; } = new();
        public PurviewExecutorOptions Options { get; }
        public PurviewExecutorClient Client { get; }
        private readonly HttpClient _http;

        public Fixture()
        {
            Options = new() { Enabled = true, Endpoint = "https://executor.azurewebsites.net", Binding = Binding };
            _http = new HttpClient(Handler);
            Client = new(new ClientFactory(_http), Microsoft.Extensions.Options.Options.Create(Options),
                Microsoft.Extensions.Options.Options.Create(new PurviewOptions
                {
                    PolicyProvisioningApplicationId = Binding.AutomationApplicationId.ToString("D"),
                    PolicyProvisioningCertificateSecretUri = Binding.CertificateSecretUri
                }), Credential);
        }
        public Task<Readback> ReadAsync() => Client.ReadAsync<object, Readback>(
            PurviewExecutorCommand.VerifyConnection, OperationId, Binding.TenantId, new { }, default);
        public Task MutateAsync() => Client.MutateAsync(PurviewExecutorCommand.CreateDlpRule,
            OperationId, Binding.TenantId, new { }, default);
        public void Dispose() => _http.Dispose();
    }

    private sealed class ClientFactory(HttpClient client) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => client;
    }
    private sealed class OfflineCredential : TokenCredential
    {
        public string? Scope { get; private set; }
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            throw new NotSupportedException();
        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken)
        {
            Scope = Assert.Single(requestContext.Scopes);
            return ValueTask.FromResult(new AccessToken("offline-test-token", DateTimeOffset.UtcNow.AddMinutes(5)));
        }
    }
    private sealed class OfflineHandler : HttpMessageHandler
    {
        public int Calls { get; private set; }
        public bool ThrowAfterDispatch { get; set; }
        public bool FailResponseStream { get; set; }
        public HttpStatusCode Status { get; set; } = HttpStatusCode.OK;
        public Func<PurviewExecutorReply, PurviewExecutorReply>? Change { get; set; }
        public Func<PurviewExecutorRequest, HttpResponseMessage>? Response { get; set; }
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Calls++;
            Assert.Equal("https://executor.azurewebsites.net/executor/v1/execute", request.RequestUri!.AbsoluteUri);
            if (ThrowAfterDispatch) throw new HttpRequestException();
            if (FailResponseStream) return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StreamContent(new BrokenResponseStream())
            };
            var envelope = (await request.Content!.ReadFromJsonAsync<PurviewExecutorRequest>(
                PurviewExecutorJson.Options, cancellationToken))!;
            if (Response is not null) return Response(envelope);
            var mutation = envelope.Command == PurviewExecutorCommand.CreateDlpRule;
            var reply = new PurviewExecutorReply(envelope.Binding, envelope.OperationId, envelope.Command,
                "Completed", mutation ? null : JsonSerializer.SerializeToElement(new Readback(true), PurviewExecutorJson.Options));
            return new HttpResponseMessage(Status)
            {
                Content = JsonContent.Create(Change?.Invoke(reply) ?? reply, options: PurviewExecutorJson.Options)
            };
        }
    }

    private sealed class BrokenResponseStream : Stream
    {
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() => throw new NotSupportedException();
        public override int Read(byte[] buffer, int offset, int count) => throw new IOException();
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) =>
            ValueTask.FromException<int>(new IOException());
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
