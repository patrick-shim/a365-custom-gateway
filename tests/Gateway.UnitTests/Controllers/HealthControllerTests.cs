using FluentAssertions;
using Gateway.Api.Controllers;
using Gateway.Infrastructure.Persistence;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using NSubstitute;

namespace Gateway.UnitTests.Controllers;

public sealed class HealthControllerTests
{
    [Fact]
    public async Task Readiness_Returns503_WhenCanConnectReturnsFalse()
    {
        var probe = Substitute.For<IDatabaseHealthProbe>();
        probe.CanConnectAsync(Arg.Any<CancellationToken>()).Returns(false);

        var result = await new HealthController().GetReadiness(probe, CancellationToken.None);

        result.Should().BeOfType<ObjectResult>()
            .Which.StatusCode.Should().Be(StatusCodes.Status503ServiceUnavailable);
    }

    [Fact]
    public async Task Readiness_Returns200_OnlyWhenCanConnectReturnsTrue()
    {
        var probe = Substitute.For<IDatabaseHealthProbe>();
        probe.CanConnectAsync(Arg.Any<CancellationToken>()).Returns(true);

        var result = await new HealthController().GetReadiness(probe, CancellationToken.None);

        result.Should().BeOfType<OkObjectResult>();
    }

    [Theory]
    [InlineData(true, StatusCodes.Status200OK)]
    [InlineData(false, StatusCodes.Status503ServiceUnavailable)]
    public async Task BootstrapAttestation_EmitsOnlyBoundedStatus(
        bool attested,
        int expectedStatus)
    {
        var service = Substitute.For<IDatabaseBootstrapAttestationService>();
        service.AttestAsync(Arg.Any<CancellationToken>()).Returns(attested);

        var result = await new HealthController().GetBootstrapAttestation(
            service,
            CancellationToken.None);

        var response = result.Should().BeAssignableTo<ObjectResult>().Subject;
        response.StatusCode.Should().Be(expectedStatus);
        var json = System.Text.Json.JsonSerializer.Serialize(response.Value);
        json.Should().Contain("contractVersion");
        var normalized = json.ToLowerInvariant();
        normalized.Should().NotContain("principal");
        normalized.Should().NotContain("schema");
        normalized.Should().NotContain("fingerprint");
    }
}
