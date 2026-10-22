using Gateway.Application.Protection;
using Gateway.Contracts;
using Gateway.Contracts.Responses;
using Gateway.Domain.Interfaces;
using MediatR;

namespace Gateway.Application.Purview.Queries;

internal sealed class GetPurviewConnectionHandler(IPurviewConnectorStore store)
    : IRequestHandler<GetPurviewConnectionQuery, PurviewConnectionResponse>
{
    public async Task<PurviewConnectionResponse> Handle(
        GetPurviewConnectionQuery request,
        CancellationToken cancellationToken)
    {
        var state = await store.GetStateAsync(request.TenantId, cancellationToken);
        if (state is null)
        {
            return new PurviewConnectionResponse(
                request.TenantId,
                request.ConfiguredConnectorInstanceId,
                "NotConfigured",
                request.ConfiguredProfile,
                "Manual",
                null, null, null, null,
                0, 0, 0,
                "Unavailable",
                null, null, null,
                "*");
        }

        var connectorMatches = request.ConfiguredConnectorInstanceId == state.ConnectorInstanceId &&
            string.Equals(request.ConfiguredProfile, state.ConnectorProfile, StringComparison.Ordinal);
        if (!connectorMatches)
        {
            return new PurviewConnectionResponse(
                state.TenantId,
                state.ConnectorInstanceId,
                "Disconnected",
                state.ConnectorProfile,
                state.RefreshMode,
                state.LastHeartbeatAtUtc,
                state.LastAttemptedRefreshAtUtc,
                state.LastSuccessfulRefreshAtUtc,
                state.CatalogRetrievedAtUtc,
                0, 0, 0,
                "Unavailable",
                null,
                ErrorCodes.PURVIEW_CONNECTOR_SETUP_REQUIRED,
                state.LastCorrelationId,
                ProtectionRowVersion.Encode(state.RowVersion, state.Id, state.UpdatedAtUtc));
        }

        return new PurviewConnectionResponse(
            state.TenantId,
            state.ConnectorInstanceId,
            state.State.ToString(),
            state.ConnectorProfile,
            state.RefreshMode,
            state.LastHeartbeatAtUtc,
            state.LastAttemptedRefreshAtUtc,
            state.LastSuccessfulRefreshAtUtc,
            state.CatalogRetrievedAtUtc,
            state.PolicyCount,
            state.CompatiblePolicyCount,
            state.IncompatiblePolicyCount,
            state.CatalogVerificationStatus,
            state.CurrentOperationId,
            state.LastFailureCode,
            state.LastCorrelationId,
            ProtectionRowVersion.Encode(state.RowVersion, state.Id, state.UpdatedAtUtc));
    }
}
