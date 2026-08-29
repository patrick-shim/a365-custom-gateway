using Gateway.Infrastructure.Persistence;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Gateway.Api.Controllers;

[ApiController]
[Route("")]
[AllowAnonymous]
public class HealthController : ControllerBase
{
    [HttpGet("health")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    public IActionResult GetHealth()
    {
        return Ok(new { status = "Healthy" });
    }

    [HttpGet("health/ready")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status503ServiceUnavailable)]
    public async Task<IActionResult> GetReadiness(
        [FromServices] IDatabaseHealthProbe database,
        CancellationToken cancellationToken)
    {
        try
        {
            if (!await database.CanConnectAsync(cancellationToken))
            {
                return StatusCode(
                    StatusCodes.Status503ServiceUnavailable,
                    new { status = "Unavailable" });
            }
            return Ok(new { status = "Ready" });
        }
        catch
        {
            return StatusCode(
                StatusCodes.Status503ServiceUnavailable,
                new { status = "Unavailable" });
        }
    }

    [HttpGet("health/bootstrap-attestation")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status503ServiceUnavailable)]
    public async Task<IActionResult> GetBootstrapAttestation(
        [FromServices] IDatabaseBootstrapAttestationService database,
        CancellationToken cancellationToken)
    {
        try
        {
            if (await database.AttestAsync(cancellationToken))
                return Ok(new { status = "Attested", contractVersion = 1 });
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            // The anonymous response is intentionally bounded. Provider/schema/
            // principal detail must never cross this health boundary.
        }

        return StatusCode(
            StatusCodes.Status503ServiceUnavailable,
            new { status = "Unavailable", contractVersion = 1 });
    }
}
