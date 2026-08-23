using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Gateway.EndToEndTests.Fixtures;
using FluentAssertions;

namespace Gateway.EndToEndTests;

[Collection(EndToEndTestCollection.Name)]
public class HealthEndpointTests : IDisposable
{
    private readonly GatewayWebApplicationFactory _factory;
    private readonly HttpClient _client;

    public HealthEndpointTests(GatewayWebApplicationFactory factory)
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
    public async Task HealthEndpoint_Should_Return200_When_ServiceIsHealthy()
    {
        // Arrange - health endpoint should be accessible
        HttpClientExtensions.SetRole("Gateway.Administrator");

        // Act
        var response = await _client.GetAsync("/health");

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.OK);

        var content = await response.Content.ReadAsStringAsync();
        content.Should().Contain("Healthy");
    }

    [Fact]
    public async Task HealthEndpoint_Should_Return200_When_Unauthenticated()
    {
        // Arrange - The HealthController is decorated with [AllowAnonymous]
        HttpClientExtensions.SetUnauthenticated();

        // Act
        var response = await _client.GetAsync("/health");

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.OK);
    }

    [Fact]
    public async Task HealthReadyEndpoint_Should_Return200_When_DatabaseIsAccessible()
    {
        // Arrange
        HttpClientExtensions.SetRole("Gateway.Administrator");

        // Act - InMemory DB should always be "connectable"
        var response = await _client.GetAsync("/health/ready");

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.OK);

        var content = await response.Content.ReadAsStringAsync();
        content.Should().Contain("Ready");
    }

    [Fact]
    public async Task HealthReadyEndpoint_Should_BeAccessible_When_Unauthenticated()
    {
        // Arrange
        HttpClientExtensions.SetUnauthenticated();

        // Act
        var response = await _client.GetAsync("/health/ready");

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.OK);
    }

    [Fact]
    public async Task HealthChecksEndpoint_Should_Return200()
    {
        // Arrange - This is the ASP.NET Health Checks endpoint registered at /health/checks
        HttpClientExtensions.SetRole("Gateway.Administrator");

        // Act
        var response = await _client.GetAsync("/health/checks");

        // Assert
        response.StatusCode.Should().Be(HttpStatusCode.OK);
    }

    [Fact]
    public async Task HealthChecksEndpoint_Should_BeAccessible_When_Unauthenticated()
    {
        // Arrange - MapHealthChecks does not require auth by default
        HttpClientExtensions.SetUnauthenticated();

        // Act
        var response = await _client.GetAsync("/health/checks");

        // Assert
        // Health checks mapped via MapHealthChecks are not protected by auth middleware
        // unless explicitly configured. They should be accessible without auth.
        response.StatusCode.Should().Be(HttpStatusCode.OK);
    }
}
