using System.Net;
using System.Text;
using System.Text.Json;
using FluentAssertions;
using Gateway.Agent365;
using Gateway.Contracts;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using NSubstitute;

namespace Gateway.ObservabilityRuntime.Tests.Agent365;

public sealed class DelegatedAgent365RegistryClientTests
{
    private static readonly Guid RegistrationId =
        Guid.Parse("01010101-0101-4101-8101-010101010101");
    private static readonly Guid OwnerObjectId =
        Guid.Parse("02020202-0202-4202-8202-020202020202");
    private static readonly Guid CreatedByObjectId =
        Guid.Parse("03030303-0303-4303-8303-030303030303");
    private static readonly Guid AgentIdentityObjectId =
        Guid.Parse("04040404-0404-4404-8404-040404040404");
    private static readonly Guid BlueprintClientId =
        Guid.Parse("05050505-0505-4505-8505-050505050505");

    [Fact]
    public async Task CreateAsync_PostsCliCompatibleDurableIdChildSourceAndAgentXManager()
    {
        var handler = new RecordingHandler((_, _) => JsonResponse(
            HttpStatusCode.Created,
            new { id = RegistrationId }));
        var client = CreateClient(handler);

        var result = await client.CreateAsync(CreateRequest(), CancellationToken.None);

        result.Should().Be(RegistrationId.ToString("D"));
        handler.Requests.Should().ContainSingle();
        var captured = handler.Requests[0];
        captured.Method.Should().Be(HttpMethod.Post);
        captured.Uri.Should().Be("https://graph.microsoft.com/beta/copilot/agentRegistrations");

        using var body = JsonDocument.Parse(captured.Body!);
        body.RootElement.GetProperty("id").GetString().Should().Be(RegistrationId.ToString("D"));
        body.RootElement.GetProperty("managedByAppId").GetString().Should().Be(
            Agent365Options.OfficialAgentXManagerApplicationId);
        body.RootElement.GetProperty("sourceAgentId").GetString().Should().Be(
            AgentIdentityObjectId.ToString("D"));
        body.RootElement.GetProperty("createdBy").GetString().Should().Be(
            CreatedByObjectId.ToString("D"));
        body.RootElement.GetProperty("ownerIds")[0].GetString().Should().Be(
            OwnerObjectId.ToString("D"));
        body.RootElement.GetProperty("agentIdentityId").GetString().Should().Be(
            AgentIdentityObjectId.ToString("D"));
        body.RootElement.GetProperty("agentIdentityBlueprintId").GetString().Should().Be(
            BlueprintClientId.ToString("D"));
        body.RootElement.TryGetProperty("sourceCreatedDateTime", out _).Should().BeTrue();
        body.RootElement.TryGetProperty("sourceLastModifiedDateTime", out _).Should().BeTrue();
    }

    [Fact]
    public async Task VerifyAsync_RetriesReadOnlyNotFoundAndValidatesExactMapping()
    {
        var handler = new RecordingHandler((_, index) => index == 0
            ? JsonResponse(HttpStatusCode.NotFound, new { })
            : RegistrationResponse());
        var client = CreateClient(handler, [TimeSpan.Zero, TimeSpan.Zero]);

        await client.VerifyAsync(
            RegistrationId.ToString("D"),
            CreateRequest(),
            CancellationToken.None);

        handler.Requests.Should().HaveCount(2);
        handler.Requests.Should().OnlyContain(candidate => candidate.Method == HttpMethod.Get);
        handler.Requests.Should().OnlyContain(candidate => candidate.Uri.EndsWith(
            $"/beta/copilot/agentRegistrations/{RegistrationId:D}",
            StringComparison.Ordinal));
    }

    [Fact]
    public async Task VerifyAsync_RejectsMissingAccountableOwner()
    {
        var handler = new RecordingHandler((_, _) => JsonResponse(HttpStatusCode.OK, new
        {
            id = RegistrationId,
            sourceAgentId = AgentIdentityObjectId,
            agentIdentityId = AgentIdentityObjectId,
            agentIdentityBlueprintId = BlueprintClientId,
            ownerIds = new[] { Guid.NewGuid() },
            createdBy = CreatedByObjectId
        }));
        var client = CreateClient(handler);

        var action = () => client.VerifyAsync(
            RegistrationId.ToString("D"),
            CreateRequest(),
            CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365DelegatedRegistryException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.MutationMayHaveOccurred.Should().BeFalse();
        handler.Requests.Should().ContainSingle();
    }

    [Theory]
    [InlineData(HttpStatusCode.BadGateway)]
    [InlineData(HttpStatusCode.ServiceUnavailable)]
    [InlineData(HttpStatusCode.GatewayTimeout)]
    public async Task CreateAsync_AmbiguousGatewayStatusDoesNotReplayOrExposeBody(
        HttpStatusCode statusCode)
    {
        const string dependencyBody = "sensitive-dependency-body";
        var handler = new RecordingHandler((_, _) => new HttpResponseMessage(
            statusCode)
        {
            Content = new StringContent(dependencyBody)
        });
        var client = CreateClient(handler);

        var action = () => client.CreateAsync(CreateRequest(), CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365DelegatedRegistryException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.MutationMayHaveOccurred.Should().BeTrue();
        exception.Which.Message.Should().NotContain(dependencyBody);
        handler.Requests.Should().ContainSingle();
        handler.Requests[0].Method.Should().Be(HttpMethod.Post);
    }

    [Fact]
    public async Task CreateAsync_HttpRequestFailureIsAmbiguousWithoutReplay()
    {
        var handler = new RecordingHandler((_, _) =>
            throw new HttpRequestException("Synthetic network failure."));
        var client = CreateClient(handler);

        var action = () => client.CreateAsync(CreateRequest(), CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365DelegatedRegistryException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.MutationMayHaveOccurred.Should().BeTrue();
        handler.Requests.Should().ContainSingle();
        handler.Requests[0].Method.Should().Be(HttpMethod.Post);
    }

    [Fact]
    public async Task CreateAsync_TimeoutIsAmbiguousWithoutReplay()
    {
        var handler = new RecordingHandler((_, _) =>
            throw new TaskCanceledException("Synthetic timeout."));
        var client = CreateClient(handler);

        var action = () => client.CreateAsync(CreateRequest(), CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365DelegatedRegistryException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.MutationMayHaveOccurred.Should().BeTrue();
        handler.Requests.Should().ContainSingle();
        handler.Requests[0].Method.Should().Be(HttpMethod.Post);
    }

    [Theory]
    [InlineData(HttpStatusCode.OK)]
    [InlineData(HttpStatusCode.Accepted)]
    [InlineData(HttpStatusCode.NoContent)]
    public async Task CreateAsync_NonCreatedSuccessStatusIsAmbiguousWithoutReplayOrBodyLeak(
        HttpStatusCode statusCode)
    {
        const string dependencyBody = "sensitive-dependency-body";
        var handler = new RecordingHandler((_, _) => JsonResponse(
            statusCode,
            new { id = RegistrationId, detail = dependencyBody }));
        var client = CreateClient(handler);

        var action = () => client.CreateAsync(CreateRequest(), CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365DelegatedRegistryException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.MutationMayHaveOccurred.Should().BeTrue();
        exception.Which.Message.Should().NotContain(dependencyBody);
        handler.Requests.Should().ContainSingle();
        handler.Requests[0].Method.Should().Be(HttpMethod.Post);
    }

    [Fact]
    public async Task CreateAsync_ConflictIsAmbiguousEvenWhenTheBodyReturnsAnId()
    {
        var existingId = Guid.Parse("07070707-0707-4707-8707-070707070707");
        var handler = new RecordingHandler((_, _) => JsonResponse(
            HttpStatusCode.Conflict,
            new { id = existingId }));
        var client = CreateClient(handler);

        var action = () => client.CreateAsync(CreateRequest(), CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365DelegatedRegistryException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.MutationMayHaveOccurred.Should().BeTrue();
        exception.Which.Message.Should().NotContain(existingId.ToString("D"));
        handler.Requests.Should().ContainSingle();
    }

    [Theory]
    [InlineData(HttpStatusCode.BadRequest)]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.Forbidden)]
    public async Task CreateAsync_DefinitiveHttpRejectionStillPreventsAnotherPost(
        HttpStatusCode statusCode)
    {
        var handler = new RecordingHandler((_, _) => JsonResponse(
            statusCode,
            new { error = "provider-body-must-not-appear" }));
        var client = CreateClient(handler);

        var action = () => client.CreateAsync(CreateRequest(), CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365DelegatedRegistryException>();
        exception.Which.MutationMayHaveOccurred.Should().BeTrue();
        exception.Which.Message.Should().NotContain("provider-body-must-not-appear");
        handler.Requests.Should().ContainSingle();
    }

    [Fact]
    public async Task CreateAsync_RejectsConflictWithoutRecoverableId()
    {
        var handler = new RecordingHandler((_, _) => JsonResponse(
            HttpStatusCode.Conflict,
            new { }));
        var client = CreateClient(handler);

        var action = () => client.CreateAsync(CreateRequest(), CancellationToken.None);

        var exception = await action.Should().ThrowAsync<Agent365DelegatedRegistryException>();
        exception.Which.ErrorCode.Should().Be(ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT);
        exception.Which.MutationMayHaveOccurred.Should().BeTrue();
        handler.Requests.Should().ContainSingle();
    }

    private static DelegatedAgent365RegistryClient CreateClient(
        RecordingHandler handler,
        IReadOnlyList<TimeSpan>? delays = null)
    {
        var tokenProvider = Substitute.For<IAgent365DelegatedTokenProvider>();
        tokenProvider.GetTokenAsync(Arg.Any<CancellationToken>())
            .Returns("delegated-token-never-logged");
        return new DelegatedAgent365RegistryClient(
            new HttpClient(handler)
            {
                BaseAddress = new Uri("https://graph.microsoft.com/"),
                Timeout = TimeSpan.FromSeconds(5)
            },
            tokenProvider,
            "A365CustomGateway",
            Agent365Options.OfficialAgentXManagerApplicationId,
            delays ?? [TimeSpan.Zero]);
    }

    private static Agent365DelegatedRegistryRequest CreateRequest() => new(
        Guid.Parse("06060606-0606-4606-8606-060606060606"),
        RegistrationId,
        "Delegated verification",
        "Safe description",
        AgentIdentityObjectId.ToString("D"),
        OwnerObjectId,
        CreatedByObjectId,
        AgentIdentityObjectId,
        BlueprintClientId,
        DateTimeOffset.Parse("2026-08-27T00:00:00Z"),
        DateTimeOffset.Parse("2026-08-27T00:01:00Z"));

    private static HttpResponseMessage RegistrationResponse() => JsonResponse(
        HttpStatusCode.OK,
        new
        {
            id = RegistrationId,
            sourceAgentId = AgentIdentityObjectId,
            agentIdentityId = AgentIdentityObjectId,
            agentIdentityBlueprintId = BlueprintClientId,
            ownerIds = new[] { OwnerObjectId },
            createdBy = CreatedByObjectId
        });

    private static HttpResponseMessage JsonResponse(HttpStatusCode status, object body) => new(status)
    {
        Content = new StringContent(
            JsonSerializer.Serialize(body),
            Encoding.UTF8,
            "application/json")
    };

    private sealed class RecordingHandler(
        Func<HttpRequestMessage, int, HttpResponseMessage> responder) : HttpMessageHandler
    {
        private int _index;

        public List<CapturedRequest> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            var body = request.Content is null
                ? null
                : await request.Content.ReadAsStringAsync(cancellationToken);
            Requests.Add(new CapturedRequest(
                request.Method,
                request.RequestUri?.AbsoluteUri ?? string.Empty,
                body));
            return responder(request, _index++);
        }
    }

    private sealed record CapturedRequest(HttpMethod Method, string Uri, string? Body);
}
