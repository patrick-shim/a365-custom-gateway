using System.Reflection;
using Gateway.AdminUi.Models;
using Gateway.AdminUi.Services;
using Gateway.Contracts.Requests;
using Gateway.Contracts.Responses;

namespace Gateway.AdminUi.BrowserHost;

// A DispatchProxy intentionally leaves newly added interface methods denied. Adding
// a production API cannot silently introduce a real transport or successful stub.
public class FixtureGatewayApi : DispatchProxy
{
    private FixtureState state = null!;
    private FixtureLease lease = null!;

    internal static IGatewayApiClient Create(FixtureState state)
    {
        var api = Create<IGatewayApiClient, FixtureGatewayApi>();
        var proxy = (FixtureGatewayApi)api;
        proxy.state = state;
        proxy.lease = state.CaptureLease();
        return api;
    }

    protected override object Invoke(MethodInfo? targetMethod, object?[]? args)
    {
        var method = targetMethod?.Name ?? throw new UnexpectedFixtureCallException("Missing API method metadata.");
        args ??= [];
        var cancellation = args.LastOrDefault() is CancellationToken token ? token : default;
        T Argument<T>(int index) => (T)args[index]!;
        Task<T> Read<T>(FixtureAccess access, Func<T> respond, Guid? target = null) =>
            state.ExecuteAsync(lease, method, access, target, false, cancellation, respond);
        Task<T> Write<T>(FixtureAccess access, Func<T> respond, Guid? target = null) =>
            state.ExecuteAsync(lease, method, access, target, true, cancellation, respond);

        return method switch
        {
            nameof(IGatewayApiClient.GetHealthAsync) =>
                Read(FixtureAccess.All, () => new GatewayHealthStatus("Healthy")),
            nameof(IGatewayApiClient.GetReadinessAsync) =>
                Read(FixtureAccess.All, () => new GatewayHealthStatus("Ready")),
            nameof(IGatewayApiClient.GetAgentsAsync) =>
                Read(FixtureAccess.All, () => state.GetAgents(Argument<AgentListQuery?>(0))),
            nameof(IGatewayApiClient.GetAgentAsync) =>
                Read(FixtureAccess.All, () => state.GetAgent(Argument<Guid>(0)), Argument<Guid>(0)),
            nameof(IGatewayApiClient.GetAgentIngressCredentialsAsync) =>
                Read(FixtureAccess.Administrator, () => state.GetCredentials(Argument<Guid>(0)), Argument<Guid>(0)),
            nameof(IGatewayApiClient.GetAgentIdentityBlueprintsAsync) =>
                Read(FixtureAccess.Administrator, state.GetBlueprints),
            nameof(IGatewayApiClient.GetSystemConfigAsync) =>
                Read(FixtureAccess.Administrator, state.GetConfig),
            nameof(IGatewayApiClient.GetPurviewPolicyProfilesAsync) =>
                Read(FixtureAccess.Administrator, () => new PurviewPolicyProfileListResponse([])),
            nameof(IGatewayApiClient.GetProtectionCapabilitiesAsync) =>
                Read(FixtureAccess.All, state.GetCapabilities),
            nameof(IGatewayApiClient.GetPurviewTenantConnectionAsync) =>
                Read(FixtureAccess.Operations, state.GetConnection),
            nameof(IGatewayApiClient.GetPurviewDlpProfilesAsync) =>
                Read(FixtureAccess.Operations, state.GetProfiles),
            nameof(IGatewayApiClient.GetPurviewSensitiveInformationTypesAsync) =>
                Read(FixtureAccess.Administrator, state.GetClassifierInventory),
            nameof(IGatewayApiClient.GetProtectionAdminOperationAsync) =>
                Read(FixtureAccess.All, () => state.GetProtectionOperation(Argument<Guid>(0)), Argument<Guid>(0)),
            nameof(IGatewayApiClient.ReviewPurviewTenantConnectionAsync) =>
                Write(FixtureAccess.Administrator, () => state.ReviewConnection(Argument<ReviewPurviewTenantConnectionRequest>(0))),
            nameof(IGatewayApiClient.ReviewPurviewTenantConnectionCompletionAsync) =>
                Write(FixtureAccess.Administrator, () => state.ReviewConnectionCompletion(Argument<Guid>(0), Argument<Guid>(1),
                    Argument<Gateway.Contracts.Dtos.PurviewTenantConnectionEvidenceDto>(2), Argument<string>(3))),
            nameof(IGatewayApiClient.ConfirmProtectionOperationReviewAsync) =>
                Write(FixtureAccess.Administrator, () => state.ConfirmProtection(Argument<ProtectionOperationReviewTicket>(0))),
            nameof(IGatewayApiClient.StartPurviewTenantConnectionOperationAsync) =>
                Write(FixtureAccess.Administrator, () => state.StartConnection(Argument<ProtectionOperationConfirmationTicket>(0))),
            nameof(IGatewayApiClient.CompletePurviewTenantConnectionOperationAsync) =>
                Write(FixtureAccess.Administrator, () => state.CompleteConnection(Argument<Guid>(0),
                    Argument<Gateway.Contracts.Dtos.PurviewTenantConnectionEvidenceDto>(1), Argument<ProtectionOperationConfirmationTicket>(2))),
            nameof(IGatewayApiClient.ReviewPurviewDlpProfileOperationAsync) =>
                Write(FixtureAccess.Administrator, () => state.ReviewPolicy(Argument<ReviewPurviewDlpProfileOperationRequest>(0))),
            nameof(IGatewayApiClient.StartPurviewDlpProfileOperationAsync) =>
                Write(FixtureAccess.Administrator, () => state.StartPolicy(Argument<ProtectionOperationConfirmationTicket>(0))),
            nameof(IGatewayApiClient.ReviewReconcilePurviewDlpProfileAsync) =>
                Write(FixtureAccess.Administrator, () => state.ReviewPolicyReadback(Argument<Guid>(0), Argument<string>(1))),
            nameof(IGatewayApiClient.ReconcilePurviewDlpProfileAsync) =>
                Write(FixtureAccess.Administrator, () => state.ReconcilePolicy(Argument<Guid>(0), Argument<ProtectionOperationConfirmationTicket>(1))),
            nameof(IGatewayApiClient.ReviewPurviewRuntimeTestAsync) =>
                Write(FixtureAccess.Administrator, () => state.ReviewRuntime(Argument<ReviewPurviewDlpRuntimeTestRequest>(0))),
            nameof(IGatewayApiClient.GetPurviewRuntimeTestAsync) =>
                Read(FixtureAccess.Administrator, () => state.GetRuntimeReport(Argument<Guid>(0)), Argument<Guid>(0)),
            nameof(IGatewayApiClient.GetPurviewKnowYourDataAsync) =>
                Read(FixtureAccess.Operations, () => FixtureState.Resource(new PurviewKnowYourDataResponse(null))),
            nameof(IGatewayApiClient.GetAgentAuditEventsAsync) =>
                Read(FixtureAccess.Audit, () => state.GetAudit(Argument<Guid>(0), Argument<AuditEventQuery?>(1)), Argument<Guid>(0)),
            nameof(IGatewayApiClient.GetProvisioningHistoryAsync) =>
                Read(FixtureAccess.Operations, () => state.GetHistory(Argument<Guid>(0)), Argument<Guid>(0)),
            nameof(IGatewayApiClient.GetOperationStatusAsync) =>
                Read(FixtureAccess.Operations, () => state.GetOperation(Argument<Guid>(0)), Argument<Guid>(0)),
            nameof(IGatewayApiClient.RegisterAgentAsync) =>
                Write(FixtureAccess.Administrator, () => state.Register(Argument<RegisterAgentRequest>(0))),
            nameof(IGatewayApiClient.IssueAgentIngressCredentialAsync) =>
                Write(FixtureAccess.Administrator, () => state.IssueCredential(Argument<Guid>(0)), Argument<Guid>(0)),
            nameof(IGatewayApiClient.RevokeAgentIngressCredentialAsync) =>
                Write(FixtureAccess.Administrator, () => state.RevokeCredential(Argument<Guid>(0), Argument<Guid>(1)), Argument<Guid>(0)),
            nameof(IGatewayApiClient.EnableAgentAsync) =>
                Write(FixtureAccess.Operations, () => state.ChangeAgentState(Argument<Guid>(0), true), Argument<Guid>(0)),
            nameof(IGatewayApiClient.DisableAgentAsync) =>
                Write(FixtureAccess.Operations, () => state.ChangeAgentState(Argument<Guid>(0), false), Argument<Guid>(0)),
            nameof(IGatewayApiClient.DeleteAgentAsync) =>
                Write(FixtureAccess.Administrator, () => state.Delete(Argument<Guid>(0)), Argument<Guid>(0)),
            nameof(IGatewayApiClient.RetryProvisioningAsync) =>
                Write(FixtureAccess.Administrator, () => state.Retry(Argument<Guid>(0)), Argument<Guid>(0)),
            nameof(IGatewayApiClient.CompleteAgent365RegistrationAsync) =>
                Write(FixtureAccess.Administrator, () => state.Complete(Argument<Guid>(0)), Argument<Guid>(0)),
            _ => throw state.RejectUnexpected(method)
        };
    }
}
