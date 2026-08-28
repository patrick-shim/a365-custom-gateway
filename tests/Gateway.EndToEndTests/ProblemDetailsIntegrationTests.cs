using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;
using Gateway.EndToEndTests.Fixtures;
using FluentAssertions;

namespace Gateway.EndToEndTests;

[Collection(EndToEndTestCollection.Name)]
public class ProblemDetailsIntegrationTests : IDisposable
{
    private readonly GatewayWebApplicationFactory _factory;
    private readonly HttpClient _client;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public ProblemDetailsIntegrationTests(GatewayWebApplicationFactory factory)
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
    public async Task NotFound_Should_ReturnRFC9457CompliantProblemDetails()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");
        var nonexistentId = Guid.NewGuid();

        // Act
        var response = await _client.GetAsync($"/api/v1/agents/{nonexistentId}");

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.NotFound);

        var content = await response.Content.ReadAsStringAsync();
        var problemDetails = JsonDocument.Parse(content);
        var root = problemDetails.RootElement;

        root.TryGetProperty("type", out _).Should().BeTrue();
        root.TryGetProperty("title", out _).Should().BeTrue();
        root.TryGetProperty("status", out var status).Should().BeTrue();
        status.GetInt32().Should().Be(404);
        root.TryGetProperty("detail", out _).Should().BeTrue();
        root.TryGetProperty("instance", out var instance).Should().BeTrue();
        instance.GetString().Should().Contain($"/api/v1/agents/{nonexistentId}");
    }

    [Fact]
    public async Task ValidationError_Should_IncludeErrorsExtension()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var request = new RegisterAgentRequest(
            ExternalAgentId: "",
            Name: "",
            Description: null,
            OwnerObjectId: "",
            Environment: "",
            Features: null,
            Blueprint: TestRequestData.ValidBlueprint);

        // Act
        var response = await _client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.BadRequest);

        var content = await response.Content.ReadAsStringAsync();
        var problemDetails = JsonDocument.Parse(content);
        var root = problemDetails.RootElement;

        root.GetProperty("errorCode").GetString().Should().Be("VALIDATION_FAILED");
        root.TryGetProperty("errors", out var errors).Should().BeTrue();
        errors.ValueKind.Should().Be(JsonValueKind.Object);
        errors.EnumerateObject().Should().NotBeEmpty();
    }

    [Fact]
    public async Task ConflictError_Should_IncludeErrorCode()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");

        var request = new RegisterAgentRequest(
            ExternalAgentId: "test-agent-conflict-pd-001",
            Name: "Conflict Agent",
            Description: null,
            OwnerObjectId: "owner-oid-001",
            Environment: "Development",
            Features: null,
            Blueprint: TestRequestData.ValidBlueprint);

        // Register first
        await _client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);

        // Act - Register duplicate
        var response = await _client.PostAsJsonAsync("/api/v1/agents", request, JsonOptions);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.Conflict);

        var content = await response.Content.ReadAsStringAsync();
        var problemDetails = JsonDocument.Parse(content);
        var root = problemDetails.RootElement;

        root.GetProperty("errorCode").GetString().Should().Be("DUPLICATE_EXTERNAL_AGENT_ID");
        root.GetProperty("status").GetInt32().Should().Be(409);
        root.TryGetProperty("type", out _).Should().BeTrue();
        root.TryGetProperty("title", out _).Should().BeTrue();
    }

    [Fact]
    public async Task ErrorResponse_Should_HaveProblemJsonContentType()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");
        var nonexistentId = Guid.NewGuid();

        // Act
        var response = await _client.GetAsync($"/api/v1/agents/{nonexistentId}");

        // Assert
        response.Content.Headers.ContentType!.MediaType.Should().Be("application/problem+json");
    }

    [Fact]
    public async Task ErrorResponse_Should_IncludeCorrelationId_When_HeaderProvided()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");
        var correlationId = "test-correlation-12345";
        var nonexistentId = Guid.NewGuid();

        var httpRequest = new HttpRequestMessage(HttpMethod.Get, $"/api/v1/agents/{nonexistentId}");
        httpRequest.Headers.Add("X-Correlation-Id", correlationId);

        // Act
        var response = await _client.SendAsync(httpRequest);

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.NotFound);

        var content = await response.Content.ReadAsStringAsync();
        var problemDetails = JsonDocument.Parse(content);
        var root = problemDetails.RootElement;

        root.TryGetProperty("correlationId", out var correlationIdProp).Should().BeTrue();
        correlationIdProp.GetString().Should().Be(correlationId);
    }

    [Fact]
    public async Task ErrorResponse_Should_GenerateCorrelationId_When_HeaderNotProvided()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");
        var nonexistentId = Guid.NewGuid();

        // Act
        var response = await _client.GetAsync($"/api/v1/agents/{nonexistentId}");

        // Assert
        var content = await response.Content.ReadAsStringAsync();
        var problemDetails = JsonDocument.Parse(content);
        var root = problemDetails.RootElement;

        root.TryGetProperty("correlationId", out var correlationIdProp).Should().BeTrue();
        correlationIdProp.GetString().Should().NotBeNullOrWhiteSpace();
    }

    [Fact]
    public async Task CorrelationId_Should_BeReturnedInResponseHeader()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");
        var correlationId = "header-test-correlation-001";

        var httpRequest = new HttpRequestMessage(HttpMethod.Get, "/api/v1/agents");
        httpRequest.Headers.Add("X-Correlation-Id", correlationId);

        // Act
        var response = await _client.SendAsync(httpRequest);

        // Assert
        response.Headers.Contains("X-Correlation-Id").Should().BeTrue();
        response.Headers.GetValues("X-Correlation-Id").First().Should().Be(correlationId);
    }

    [Fact]
    public async Task CorrelationId_Should_BeGeneratedInResponseHeader_When_NotProvided()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");

        // Act
        var response = await _client.GetAsync("/api/v1/agents");

        // Assert
        response.Headers.Contains("X-Correlation-Id").Should().BeTrue();
        var generatedId = response.Headers.GetValues("X-Correlation-Id").First();
        generatedId.Should().NotBeNullOrWhiteSpace();
        Guid.TryParse(generatedId, out _).Should().BeTrue();
    }
}
