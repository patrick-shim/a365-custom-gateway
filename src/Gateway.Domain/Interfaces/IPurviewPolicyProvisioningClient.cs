using Gateway.Domain.Models;

namespace Gateway.Domain.Interfaces;

public interface IPurviewPolicyProvisioningClient
{
    bool IsEnabled { get; }

    Task<PurviewPolicyProvisioningResult> EnsureProfileAssignmentAsync(
        PurviewPolicyProvisioningRequest request,
        CancellationToken ct);

    Task<PurviewPolicyProvisioningResult> VerifyProfileAssignmentAsync(
        PurviewPolicyProvisioningRequest request,
        CancellationToken ct);
}
