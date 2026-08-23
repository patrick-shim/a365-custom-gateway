using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.EndToEndTests.Fixtures;
using FluentAssertions;

namespace Gateway.EndToEndTests;

[Collection(EndToEndTestCollection.Name)]
public class ValidationTests : IDisposable
{
    private readonly GatewayWebApplicationFactory _factory;
    private readonly HttpClient _client;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public ValidationTests(GatewayWebApplicationFactory factory)
    {
        _factory = factory;
        _client = factory.CreateAuthenticatedClient();
    }

    public void Dispose()
    {
        _client.Dispose();
        TestAuthHandler.Reset();
    }

    [Fact]
    public async Task RegisterAgent_Should_Return400_When_ExternalAgentIdIsEmpty()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var request = new RegisterAgentRequest(
            ExternalAgentId: "",
            Name: "Test Agent",
            Description: null,
            OwnerObjectId: "owner-oid-001",
            Environment: "Development",
            Features: null);

        // Act
        var response = await _client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);

        var content = await response.Content.ReadAsStringAsync();
        var problemDetails = JsonDocument.Parse(content);
        problemDetails.RootElement.GetProperty("errorCode").GetString()
            .Should().Be("VALIDATION_FAILED");
        problemDetails.RootElement.TryGetProperty("errors", out var errors).Should().BeTrue();
        errors.GetRawText().Should().Contain("ExternalAgentId");
    }

    [Fact]
    public async Task RegisterAgent_Should_Return400_When_EnvironmentIsInvalid()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var request = new RegisterAgentRequest(
            ExternalAgentId: "test-agent-invalid-env",
            Name: "Test Agent",
            Description: null,
            OwnerObjectId: "owner-oid-001",
            Environment: "InvalidEnvironment",
            Features: null);

        // Act
        var response = await _client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);

        var content = await response.Content.ReadAsStringAsync();
        var problemDetails = JsonDocument.Parse(content);
        problemDetails.RootElement.GetProperty("errorCode").GetString()
            .Should().Be("VALIDATION_FAILED");
        problemDetails.RootElement.TryGetProperty("errors", out var errors).Should().BeTrue();
        errors.GetRawText().Should().Contain("Environment");
    }

    [Fact]
    public async Task RegisterAgent_Should_Return400_When_ExternalAgentIdHasInvalidChars()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var request = new RegisterAgentRequest(
            ExternalAgentId: "agent@test!invalid",
            Name: "Test Agent",
            Description: null,
            OwnerObjectId: "owner-oid-001",
            Environment: "Development",
            Features: null);

        // Act
        var response = await _client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);

        var content = await response.Content.ReadAsStringAsync();
        var problemDetails = JsonDocument.Parse(content);
        problemDetails.RootElement.GetProperty("errorCode").GetString()
            .Should().Be("VALIDATION_FAILED");
        problemDetails.RootElement.TryGetProperty("errors", out var errors).Should().BeTrue();
        errors.GetRawText().Should().Contain("ExternalAgentId");
    }

    [Fact]
    public async Task RegisterAgent_Should_Return400_When_NameIsEmpty()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var request = new RegisterAgentRequest(
            ExternalAgentId: "test-agent-no-name",
            Name: "",
            Description: null,
            OwnerObjectId: "owner-oid-001",
            Environment: "Development",
            Features: null);

        // Act
        var response = await _client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);

        var content = await response.Content.ReadAsStringAsync();
        var problemDetails = JsonDocument.Parse(content);
        problemDetails.RootElement.GetProperty("errorCode").GetString()
            .Should().Be("VALIDATION_FAILED");
        problemDetails.RootElement.TryGetProperty("errors", out var errors).Should().BeTrue();
        errors.GetRawText().Should().Contain("Name");
    }

    [Fact]
    public async Task RegisterAgent_Should_Return400_When_OwnerObjectIdIsEmpty()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var request = new RegisterAgentRequest(
            ExternalAgentId: "test-agent-no-owner",
            Name: "Agent Without Owner",
            Description: null,
            OwnerObjectId: "",
            Environment: "Development",
            Features: null);

        // Act
        var response = await _client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);

        var content = await response.Content.ReadAsStringAsync();
        var problemDetails = JsonDocument.Parse(content);
        problemDetails.RootElement.GetProperty("errorCode").GetString()
            .Should().Be("VALIDATION_FAILED");
        problemDetails.RootElement.TryGetProperty("errors", out var errors).Should().BeTrue();
        errors.GetRawText().Should().Contain("OwnerObjectId");
    }

    [Fact]
    public async Task RegisterAgent_Should_Return202_When_AllFieldsAreValid()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var request = new RegisterAgentRequest(
            ExternalAgentId: $"valid-agent-{Guid.NewGuid():N}".Substring(0, 40),
            Name: "Fully Valid Agent",
            Description: "A properly configured agent",
            OwnerObjectId: "owner-oid-001",
            Environment: "Production",
            Features: new AgentFeaturesDto(
                ObservabilityMode: "GatewayOnly",
                PurviewEnabled: false,
                PurviewMode: null));

        // Act
        var response = await _client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.Accepted);
    }

    [Fact]
    public async Task RegisterAgent_Should_Return400_When_ExternalAgentIdStartsWithSpecialChar()
    {
        // Arrange - ExternalAgentId must start with alphanumeric per regex ^[a-zA-Z0-9]
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var request = new RegisterAgentRequest(
            ExternalAgentId: ".starts-with-dot",
            Name: "Test Agent",
            Description: null,
            OwnerObjectId: "owner-oid-001",
            Environment: "Development",
            Features: null);

        // Act
        var response = await _client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);
    }

    [Fact]
    public async Task RegisterAgent_Should_Return400_When_MultipleFieldsAreInvalid()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var request = new RegisterAgentRequest(
            ExternalAgentId: "",
            Name: "",
            Description: null,
            OwnerObjectId: "",
            Environment: "",
            Features: null);

        // Act
        var response = await _client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);

        var content = await response.Content.ReadAsStringAsync();
        var problemDetails = JsonDocument.Parse(content);

        // Multiple validation errors should be present
        var errors = problemDetails.RootElement.GetProperty("errors");
        errors.EnumerateObject().Count().Should().BeGreaterThan(1);
    }
}
