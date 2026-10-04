using Gateway.Contracts.Responses;
using Gateway.Api.Authorization;
using Gateway.Api.Extensions;
using Gateway.Domain.Models;
using Gateway.Purview;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Gateway.Api.Controllers;

[ApiController]
[Route("api/v1/protection/purview/policies")]
[Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
public sealed class PurviewPolicyCatalogController(IPurviewPolicyCatalogClient catalog) : ControllerBase
{
    [HttpGet]
    [ProducesResponseType(typeof(PurviewPolicyCatalogResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status503ServiceUnavailable)]
    public async Task<IActionResult> List(CancellationToken cancellationToken)
    {
        Response.Headers.CacheControl = "no-store";
        try
        {
            var result = await catalog.ReadAsync(User.GetProtectionActor().TenantId, cancellationToken);
            return Ok(new PurviewPolicyCatalogResponse(result.TenantId, result.RetrievedAtUtc, "Purview",
                result.Items.Select(policy => new PurviewPolicyResponse(policy.Id, policy.DisplayName,
                    policy.Mode, policy.EnforcementPlanes, policy.IndividualApplicationIds, policy.Revision,
                    new PolicyCompatibilityResponse(PurviewPolicyCatalogValidation.Incompatibility(policy) is null,
                        PurviewPolicyCatalogValidation.Incompatibility(policy))))));
        }
        catch (PurviewPolicyException failure)
        {
            return StatusCode(503, new ProblemDetails
            {
                Status = 503, Title = "Purview policy catalog unavailable",
                Detail = failure.FailureCode == "PURVIEW_POLICY_CATALOG_SETUP_REQUIRED"
                    ? "Configure unattended Purview policy access during deployment setup. Saved gateway profiles are separate from the live policy catalog."
                    : "The gateway could not obtain a current policy catalog from Purview. No empty or cached success was substituted.",
                Extensions = { ["errorCode"] = failure.FailureCode }
            });
        }
    }
}
