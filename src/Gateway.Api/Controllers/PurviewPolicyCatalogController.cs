using Gateway.Contracts.Responses;
using Gateway.Api.Authorization;
using Gateway.Api.Extensions;
using Gateway.Api.Infrastructure;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;
using Gateway.Purview;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Options;

namespace Gateway.Api.Controllers;

[ApiController]
[Route("api/v1/protection/purview/policies")]
[Authorize(Policy = AuthorizationPolicies.AdministratorOnly)]
public sealed class PurviewPolicyCatalogController(
    IPurviewConnectorStore connectorStore,
    IOptions<PurviewConnectorOptions> connectorOptions) : ControllerBase
{
    [HttpGet]
    [ProducesResponseType(typeof(PurviewPolicyCatalogResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status503ServiceUnavailable)]
    public async Task<IActionResult> List(CancellationToken cancellationToken)
    {
        Response.Headers.CacheControl = "no-store";
        try
        {
            var tenantId = User.GetProtectionActor().TenantId;
            var connectorInstanceId = connectorOptions.Value.TenantId == tenantId
                ? connectorOptions.Value.ConnectorInstanceId
                : Guid.Empty;
            if (connectorInstanceId == Guid.Empty)
                throw new PurviewPolicyException(
                    "PURVIEW_POLICY_CATALOG_SETUP_REQUIRED",
                    "The bootstrap-owned Purview connector is not configured for this tenant.");
            var snapshot = await connectorStore.GetAcceptedCatalogAsync(
                    tenantId, connectorInstanceId, cancellationToken)
                ?? throw new PurviewPolicyException(
                    "PURVIEW_POLICY_CATALOG_SETUP_REQUIRED",
                    "No authenticated Purview policy catalog has been accepted.");
            var result = AcceptedPurviewCatalog.Deserialize(snapshot, tenantId, connectorInstanceId);
            return Ok(new PurviewPolicyCatalogResponse(result.TenantId, result.RetrievedAtUtc, "AcceptedPurviewConnectorSnapshot",
                result.Items.Select(policy => new PurviewPolicyResponse(policy.Id, policy.DisplayName,
                    policy.Mode, policy.EnforcementPlanes, policy.IndividualApplicationIds, policy.Revision,
                    new PolicyCompatibilityResponse(PurviewPolicyCatalogValidation.Incompatibility(policy) is null,
                        PurviewPolicyCatalogValidation.Incompatibility(policy))))));
        }
        catch (PurviewPolicyException failure)
        {
            var failureCode = failure.FailureCode;
            return StatusCode(503, new ProblemDetails
            {
                Status = 503, Title = "Purview policy catalog unavailable",
                Detail = failureCode == "PURVIEW_POLICY_CATALOG_SETUP_REQUIRED"
                    ? "Connect Purview and complete an authenticated policy refresh before selecting a policy."
                    : "The Gateway could not verify its accepted Purview policy catalog. No empty success was substituted.",
                Extensions = { ["errorCode"] = failureCode }
            });
        }
    }
}
