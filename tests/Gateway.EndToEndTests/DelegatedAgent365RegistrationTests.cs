using System.Net;
using System.Net.Http.Json;
using System.Security.Claims;
using System.Text;
using System.Text.Json;
using FluentAssertions;
using Gateway.Contracts;
using Gateway.Contracts.Messages;
using Gateway.Contracts.Responses;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Domain.ValueObjects;
using Gateway.EndToEndTests.Fixtures;
using Gateway.Infrastructure.Persistence;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Identity.Client;
using Microsoft.Identity.Web;
using NSubstitute;

namespace Gateway.EndToEndTests;

[Collection(EndToEndTestCollection.Name)]
public sealed class DelegatedAgent365RegistrationTests : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly GatewayWebApplicationFactory _factory;
    private readonly HttpClient _client;

    public DelegatedAgent365RegistrationTests(GatewayWebApplicationFactory factory)
    {
        _factory = factory;
        _client = factory.CreateAuthenticatedClient();
        ResetDelegatedSubstitutes();
    }

    public void Dispose()
    {
        _client.Dispose();
        TestAuthHandler.Reset();
    }

    [Fact]
    public async Task Completion_ShouldCreateExactlyOnceAndSecondCallShouldBeIdempotent()
    {
        var scenario = await SeedAwaitingWorkflowAsync(
            _factory.Services,
            workflowVersion: ProvisioningWorkflow.CurrentVersion);
        var registryId = Guid.NewGuid().ToString("D");
        _factory.MockDelegatedRegistryClient.CreateAsync(
                Arg.Any<Agent365DelegatedRegistryRequest>(),
                Arg.Any<CancellationToken>())
            .Returns(registryId);
        HttpClientExtensions.SetDelegatedAdministrator(scenario.CallerObjectId);

        var firstResponse = await _client.PostAsync(
            $"/api/v1/operations/{scenario.JobId:D}:complete-agent365-registration",
            content: null);
        var secondResponse = await _client.PostAsync(
            $"/api/v1/operations/{scenario.JobId:D}:complete-agent365-registration",
            content: null);

        firstResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        secondResponse.StatusCode.Should().Be(HttpStatusCode.OK);
        var result = await firstResponse.Content.ReadFromJsonAsync<
            CompleteAgent365RegistrationResponse>(JsonOptions);
        result.Should().NotBeNull();
        result!.OperationId.Should().Be(scenario.JobId);
        result.AgentId.Should().Be(scenario.AgentId);
        result.Agent365RegistrationId.Should().Be(registryId);
        var responseBody = await secondResponse.Content.ReadAsStringAsync();
        responseBody.Contains("apiKey", StringComparison.OrdinalIgnoreCase).Should().BeFalse();
        responseBody.Contains("accessToken", StringComparison.OrdinalIgnoreCase).Should().BeFalse();
        responseBody.Contains("authorization", StringComparison.OrdinalIgnoreCase).Should().BeFalse();

        await _factory.MockDelegatedTokenProvider.Received(1)
            .GetTokenAsync(Arg.Any<CancellationToken>());
        await _factory.MockDelegatedRegistryClient.Received(1).CreateAsync(
            Arg.Is<Agent365DelegatedRegistryRequest>(request =>
                request.RequestCorrelationId == scenario.JobId &&
                request.CreatedByObjectId == Guid.Parse(scenario.CallerObjectId) &&
                request.OwnerObjectId == Guid.Parse(scenario.CallerObjectId)),
            Arg.Any<CancellationToken>());
        await _factory.MockDelegatedRegistryClient.DidNotReceiveWithAnyArgs()
            .VerifyAsync(default!, default!, default);

        await using var scope = _factory.Services.CreateAsyncScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        var job = await dbContext.ProvisioningJobs
            .Include(existing => existing.Steps)
            .SingleAsync(existing => existing.Id == scenario.JobId);
        job.Status.Should().Be(JobStatus.Running);
        job.PercentComplete.Should().Be(85);
        var registerStep = job.Steps.Single(step =>
            step.StepType == ProvisioningStepType.RegisterAgent);
        registerStep.Status.Should().Be(StepStatus.Completed);
        var completed = JsonSerializer.Deserialize<Agent365ProvisioningStepResult>(
            registerStep.ResultData!);
        completed!.State.Agent365RegistrationId.Should().Be(registryId);
        completed.State.RegistryAuthenticationMode.Should().Be("DelegatedAdministrator");
        completed.State.RegistryCreatedByObjectId.Should().Be(scenario.CallerObjectId);
        completed.State.Agent365RegistrationAcceptedAtUtc.Should().NotBeNull();
        completed.State.Agent365RegistrationVerifiedAtUtc.Should().BeNull();

        var outbox = await dbContext.OutboxMessages
            .Where(message => message.MessageType == "ProvisionAgent")
            .ToListAsync();
        var matchingOutbox = outbox.Where(message =>
            {
                var payload = JsonSerializer.Deserialize<ProvisionAgentMessage>(message.Payload);
                return payload is not null &&
                       payload.JobId == scenario.JobId &&
                       payload.ExpectedStepIndex == 6;
            })
            .ToList();
        matchingOutbox.Should().ContainSingle();
        (await dbContext.AuditEvents.CountAsync(audit =>
            audit.AgentRegistrationId == scenario.AgentId &&
            audit.EventType == "Agent365RegistryAcceptedByAdministrator"))
            .Should().Be(1);
    }

    [Fact]
    public async Task Completion_ShouldRejectHistoricalAmbiguousVersionTwoWithoutRegistryMutation()
    {
        var scenario = await SeedAwaitingWorkflowAsync(
            _factory.Services,
            workflowVersion: 2,
            manualRegistryFailure: true);
        HttpClientExtensions.SetDelegatedAdministrator(scenario.CallerObjectId);

        var response = await _client.PostAsync(
            $"/api/v1/operations/{scenario.JobId:D}:complete-agent365-registration",
            content: null);

        response.StatusCode.Should().Be(HttpStatusCode.Conflict);
        var problem = await response.Content.ReadFromJsonAsync<JsonElement>(JsonOptions);
        problem.GetProperty("errorCode").GetString().Should().Be(ErrorCodes.PROVISIONING_LEGACY_JOB);
        await _factory.MockDelegatedRegistryClient.DidNotReceiveWithAnyArgs()
            .CreateAsync(default!, default);
        await _factory.MockDelegatedRegistryClient.DidNotReceiveWithAnyArgs()
            .VerifyAsync(default!, default!, default);

        await using var scope = _factory.Services.CreateAsyncScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        (await dbContext.OutboxMessages.AnyAsync(message =>
            message.Payload.Contains(scenario.JobId.ToString("D"))))
            .Should().BeFalse();
    }

    [Fact]
    public async Task Completion_ShouldReturn503BeforeTokenOrRegistryCallWhenActionGateIsClosed()
    {
        using var disabledFactory = CreateFactory(
            delegatedRegistryEnabled: false,
            actionExpiresAtUtc: null);
        using var client = disabledFactory.CreateClient();
        _factory.MockDelegatedTokenProvider.ClearReceivedCalls();
        _factory.MockDelegatedRegistryClient.ClearReceivedCalls();
        HttpClientExtensions.SetDelegatedAdministrator();

        var response = await client.PostAsync(
            $"/api/v1/operations/{Guid.NewGuid():D}:complete-agent365-registration",
            content: null);

        response.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);
        var problem = await response.Content.ReadFromJsonAsync<JsonElement>(JsonOptions);
        problem.GetProperty("errorCode").GetString().Should().Be(ErrorCodes.PROVISIONING_DISABLED);
        await _factory.MockDelegatedTokenProvider.DidNotReceiveWithAnyArgs()
            .GetTokenAsync(default);
        await _factory.MockDelegatedRegistryClient.DidNotReceiveWithAnyArgs()
            .CreateAsync(default!, default);
    }

    [Fact]
    public async Task Completion_ShouldReturn503BeforeTokenOrRegistryCallForAnUnboundOperation()
    {
        var authorizedOperationId = Guid.NewGuid();
        using var boundFactory = CreateFactory(
            delegatedRegistryEnabled: true,
            actionExpiresAtUtc: "2099-01-01T00:00:00Z",
            requireExactActionBinding: true,
            authorizedOperationId: authorizedOperationId.ToString("D"));
        using var client = boundFactory.CreateClient();
        _factory.MockDelegatedTokenProvider.ClearReceivedCalls();
        _factory.MockDelegatedRegistryClient.ClearReceivedCalls();
        HttpClientExtensions.SetDelegatedAdministrator();

        var response = await client.PostAsync(
            $"/api/v1/operations/{Guid.NewGuid():D}:complete-agent365-registration",
            content: null);

        response.StatusCode.Should().Be(HttpStatusCode.ServiceUnavailable);
        var problem = await response.Content.ReadFromJsonAsync<JsonElement>(JsonOptions);
        problem.GetProperty("errorCode").GetString().Should().Be(ErrorCodes.PROVISIONING_DISABLED);
        await _factory.MockDelegatedTokenProvider.DidNotReceiveWithAnyArgs()
            .GetTokenAsync(default);
        await _factory.MockDelegatedRegistryClient.DidNotReceiveWithAnyArgs()
            .CreateAsync(default!, default);
    }

    [Fact]
    public async Task Completion_ShouldReturnSafeStandardsCompatibleClaimsChallengeBeforeMutation()
    {
        var scenario = await SeedAwaitingWorkflowAsync(
            _factory.Services,
            workflowVersion: ProvisioningWorkflow.CurrentVersion);
        var tenantId = Guid.NewGuid();
        var requiredScopes = new[]
        {
            "https://graph.microsoft.com/AgentRegistration.ReadWrite.All",
            "https://graph.microsoft.com/AgentRegistration.Read.All"
        };
        const string rawClaims =
            "{\"access_token\":{\"acrs\":{\"essential\":true,\"value\":\"c1\"}}}";
        const string sensitiveIdentityMessage = "Bearer secret-upstream-diagnostic";
        var msalException = new MsalUiRequiredException(
            "interaction_required",
            sensitiveIdentityMessage);
        typeof(MsalServiceException)
            .GetField(
                "<Claims>k__BackingField",
                System.Reflection.BindingFlags.Instance |
                System.Reflection.BindingFlags.NonPublic)!
            .SetValue(msalException, rawClaims);
        var challengeException = new MicrosoftIdentityWebChallengeUserException(
            msalException,
            requiredScopes);
        _factory.MockDelegatedTokenProvider.GetTokenAsync(Arg.Any<CancellationToken>())
            .Returns(Task.FromException<string>(challengeException));
        HttpClientExtensions.SetClaims(
            new Claim(ClaimTypes.Role, "Gateway.Administrator"),
            new Claim("oid", scenario.CallerObjectId),
            new Claim("scp", "access_as_user"),
            new Claim("tid", tenantId.ToString("D")));
        var correlationId = Guid.NewGuid().ToString("D");
        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            $"/api/v1/operations/{scenario.JobId:D}:complete-agent365-registration");
        request.Headers.TryAddWithoutValidation("X-Correlation-ID", correlationId);

        using var response = await _client.SendAsync(request);

        response.StatusCode.Should().Be(HttpStatusCode.Unauthorized);
        response.Content.Headers.ContentType?.MediaType.Should().Be("application/problem+json");
        var authenticate = response.Headers.WwwAuthenticate.Should().ContainSingle().Subject;
        authenticate.Scheme.Should().Be("Bearer");
        authenticate.Parameter.Should().Contain("error=\"insufficient_claims\"");
        authenticate.Parameter.Should().Contain(
            $"authorization_uri=\"https://login.microsoftonline.com/{tenantId:D}/oauth2/v2.0/authorize\"");
        authenticate.Parameter.Should().Contain(
            $"claims=\"{Convert.ToBase64String(Encoding.UTF8.GetBytes(rawClaims))}\"");
        authenticate.Parameter.Should().NotContain(rawClaims);
        authenticate.Parameter.Should().NotContain(sensitiveIdentityMessage);

        var body = await response.Content.ReadAsStringAsync();
        body.Should().NotContain(rawClaims);
        body.Should().NotContain(sensitiveIdentityMessage);
        var problem = JsonSerializer.Deserialize<JsonElement>(body, JsonOptions);
        problem.GetProperty("status").GetInt32().Should().Be(401);
        problem.GetProperty("errorCode").GetString().Should().Be(
            ErrorCodes.AGENT365_REGISTRY_DELEGATED_ACCESS_REQUIRED);
        problem.GetProperty("challengeType").GetString().Should().Be("claims_challenge");
        problem.GetProperty("claimsChallenge").GetBoolean().Should().BeTrue();
        problem.GetProperty("correlationId").GetString().Should().Be(correlationId);
        problem.GetProperty("requiredScopes")
            .EnumerateArray()
            .Select(value => value.GetString())
            .Should()
            .Equal(requiredScopes);
        await _factory.MockDelegatedRegistryClient.DidNotReceiveWithAnyArgs()
            .CreateAsync(default!, default);

        await using var scope = _factory.Services.CreateAsyncScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        var job = await dbContext.ProvisioningJobs
            .Include(existing => existing.Steps)
            .SingleAsync(existing => existing.Id == scenario.JobId);
        job.Status.Should().Be(JobStatus.AwaitingAdministratorAction);
        job.Steps.Single(step => step.StepType == ProvisioningStepType.RegisterAgent)
            .Status.Should().Be(StepStatus.Pending);
    }

    [Fact]
    public async Task Completion_ShouldRejectAppOnlyAdministratorBeforeTokenOrRegistryCall()
    {
        HttpClientExtensions.SetClaims(
            new Claim(ClaimTypes.Role, "Gateway.Administrator"),
            new Claim("oid", TestAuthHandler.DefaultObjectId),
            new Claim("roles", "Gateway.Administrator"));

        var response = await _client.PostAsync(
            $"/api/v1/operations/{Guid.NewGuid():D}:complete-agent365-registration",
            content: null);

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        await _factory.MockDelegatedTokenProvider.DidNotReceiveWithAnyArgs()
            .GetTokenAsync(default);
        await _factory.MockDelegatedRegistryClient.DidNotReceiveWithAnyArgs()
            .CreateAsync(default!, default);
    }

    [Fact]
    public async Task Completion_ShouldRejectDelegatedOperatorBeforeTokenOrRegistryCall()
    {
        HttpClientExtensions.SetClaims(
            new Claim(ClaimTypes.Role, "Gateway.Operator"),
            new Claim("oid", TestAuthHandler.DefaultObjectId),
            new Claim("scp", "access_as_user"));

        var response = await _client.PostAsync(
            $"/api/v1/operations/{Guid.NewGuid():D}:complete-agent365-registration",
            content: null);

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        await _factory.MockDelegatedTokenProvider.DidNotReceiveWithAnyArgs()
            .GetTokenAsync(default);
        await _factory.MockDelegatedRegistryClient.DidNotReceiveWithAnyArgs()
            .CreateAsync(default!, default);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("not-a-guid")]
    [InlineData("00000000-0000-0000-0000-000000000000")]
    public async Task Completion_ShouldRejectMissingOrInvalidOidBeforeAction(string? objectId)
    {
        var claims = new List<Claim>
        {
            new(ClaimTypes.Role, "Gateway.Administrator"),
            new("scp", "access_as_user")
        };
        claims.Add(new Claim("oid", objectId ?? string.Empty));
        HttpClientExtensions.SetClaims(claims.ToArray());

        var response = await _client.PostAsync(
            $"/api/v1/operations/{Guid.NewGuid():D}:complete-agent365-registration",
            content: null);

        response.StatusCode.Should().Be(HttpStatusCode.Forbidden);
        await _factory.MockDelegatedTokenProvider.DidNotReceiveWithAnyArgs()
            .GetTokenAsync(default);
        await _factory.MockDelegatedRegistryClient.DidNotReceiveWithAnyArgs()
            .CreateAsync(default!, default);
    }

    private WebApplicationFactory<Program> CreateFactory(
        bool delegatedRegistryEnabled,
        string? actionExpiresAtUtc,
        bool requireExactActionBinding = false,
        string? authorizedOperationId = null) =>
        _factory.WithWebHostBuilder(builder =>
            builder.ConfigureAppConfiguration((_, configuration) =>
                configuration.AddInMemoryCollection(new Dictionary<string, string?>
                {
                    ["Agent365:DelegatedRegistry:Enabled"] = delegatedRegistryEnabled.ToString(),
                    ["Agent365:DelegatedRegistry:ActionExpiresAtUtc"] = actionExpiresAtUtc,
                    ["Agent365:DelegatedRegistry:RequireExactActionBinding"] =
                        requireExactActionBinding.ToString(),
                    ["Agent365:DelegatedRegistry:AuthorizedOperationId"] = authorizedOperationId
                })));

    private void ResetDelegatedSubstitutes()
    {
        _factory.MockDelegatedRegistryClient.ClearReceivedCalls();
        _factory.MockDelegatedTokenProvider.ClearReceivedCalls();
        _factory.MockProvisioningExecutionLockProvider.ClearReceivedCalls();
        _factory.MockDelegatedTokenProvider.GetTokenAsync(Arg.Any<CancellationToken>())
            .Returns("opaque-test-value");
    }

    private static async Task<SeededScenario> SeedAwaitingWorkflowAsync(
        IServiceProvider services,
        int workflowVersion,
        bool manualRegistryFailure = false)
    {
        var callerObjectId = Guid.NewGuid().ToString("D");
        var state = new Agent365ProvisioningState
        {
            BlueprintObjectId = Guid.NewGuid().ToString("D"),
            BlueprintClientId = Guid.NewGuid().ToString("D"),
            BlueprintPrincipalObjectId = Guid.NewGuid().ToString("D"),
            GatewayManagedIdentityPrincipalId = Guid.NewGuid().ToString("D"),
            GatewayFederatedCredentialId = "fic-resource-id_123",
            AgentIdentityObjectId = Guid.NewGuid().ToString("D"),
            AgentIdentityClientId = Guid.NewGuid().ToString("D"),
            ObservabilityAppRoleAssignmentId = "Lo6gEKI-4EyAy9X91LBepo6Aq0Rt6QxBjWRl76txk8I"
        };
        var agent = new AgentRegistration
        {
            Id = Guid.NewGuid(),
            ExternalAgentId = new ExternalAgentId($"agent-{Guid.NewGuid():N}"),
            Name = "Delegated Registry E2E canary",
            Description = "Synthetic test only",
            OwnerObjectId = callerObjectId,
            Environment = AgentEnvironment.Development,
            Status = manualRegistryFailure
                ? AgentStatus.RequiresManualIntervention
                : AgentStatus.AwaitingAdminApproval,
            CreatedAtUtc = DateTime.UtcNow.AddMinutes(-5),
            UpdatedAtUtc = DateTime.UtcNow.AddMinutes(-1),
            CreatedByObjectId = callerObjectId,
            UpdatedByObjectId = callerObjectId,
            FeatureConfiguration = new AgentFeatureConfiguration
            {
                Id = Guid.NewGuid(),
                ObservabilityMode = ObservabilityMode.Agent365,
                UpdatedAtUtc = DateTime.UtcNow.AddMinutes(-1)
            }
        };
        agent.FeatureConfiguration.AgentRegistrationId = agent.Id;

        var job = new ProvisioningJob
        {
            Id = Guid.NewGuid(),
            AgentRegistrationId = agent.Id,
            Type = OperationType.ProvisionAgent,
            Status = manualRegistryFailure
                ? JobStatus.RequiresManualIntervention
                : JobStatus.AwaitingAdministratorAction,
            PercentComplete = 71,
            WorkflowVersion = workflowVersion,
            ErrorCode = manualRegistryFailure
                ? ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT
                : null,
            StartedAtUtc = DateTime.UtcNow.AddMinutes(-5),
            CreatedAtUtc = DateTime.UtcNow.AddMinutes(-5)
        };
        job.Steps = ProvisioningWorkflow.CurrentSteps
            .Select((stepType, index) => new ProvisioningJobStep
            {
                Id = Guid.NewGuid(),
                ProvisioningJobId = job.Id,
                StepType = stepType,
                OrderIndex = index,
                Status = index < 5
                    ? StepStatus.Completed
                    : index == 5 && manualRegistryFailure
                        ? StepStatus.Failed
                        : StepStatus.Pending,
                ErrorCode = index == 5 && manualRegistryFailure
                    ? ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT
                    : null,
                CompletedAtUtc = index < 5 || index == 5 && manualRegistryFailure
                    ? DateTime.UtcNow.AddMinutes(-1)
                    : null,
                ResultData = index < 5
                    ? JsonSerializer.Serialize(new Agent365ProvisioningStepResult(
                        stepType,
                        state,
                        $"verified_{stepType}"))
                    : null
            })
            .ToList();

        await using var scope = services.CreateAsyncScope();
        var dbContext = scope.ServiceProvider.GetRequiredService<GatewayDbContext>();
        dbContext.AgentRegistrations.Add(agent);
        dbContext.ProvisioningJobs.Add(job);
        await dbContext.SaveChangesAsync();
        return new SeededScenario(callerObjectId, agent.Id, job.Id);
    }

    private sealed record SeededScenario(string CallerObjectId, Guid AgentId, Guid JobId);
}
