using Gateway.Domain.Models;
using Gateway.Purview;
using Microsoft.Extensions.Options;

namespace Gateway.Provisioning.Worker;

internal sealed class RemotePurviewConnectionVerificationProvider(
    IPurviewExecutorClient executor,
    IOptions<PurviewExecutorOptions> options) : IPurviewConnectionVerificationProvider
{
    public async Task<PurviewConnectionVerificationEvidence> VerifyAsync(
        PurviewConnectionVerificationRequest request, CancellationToken ct)
    {
        var binding = options.Value.Binding;
        if (binding is null || request.TenantId != binding.TenantId ||
            request.ExpectedAuthorityApplicationId != binding.AutomationApplicationId ||
            request.ExpectedAuthorityServicePrincipalObjectId != binding.AutomationServicePrincipalObjectId ||
            request.ExpectedKeyVaultResourceId != binding.KeyVaultResourceId ||
            request.ExpectedCertificateName != binding.CertificateName ||
            request.ExpectedCertificateSecretUri.AbsoluteUri != binding.CertificateSecretUri)
            throw new PurviewPolicyException("PURVIEW_EXECUTOR_CAPABILITY_MISMATCH",
                "The connection request does not match the deployed execution binding.");
        try
        {
            return await executor.ReadAsync<PurviewConnectionVerificationRequest, PurviewConnectionVerificationEvidence>(
                PurviewExecutorCommand.VerifyConnection, request.OperationId, request.TenantId, request, ct);
        }
        catch (PurviewPolicyException exception)
        {
            var retryableRead = exception.IsTransient &&
                exception.FailureCode == "PURVIEW_EXECUTOR_CONNECTION_READ_TIMEOUT";
            throw new PurviewConnectionVerificationException(
                retryableRead ? "PURVIEW_CONNECTION_READ_TIMEOUT" : "PURVIEW_CONNECTION_PROVIDER_UNVERIFIED",
                isTransient: retryableRead);
        }
    }
}
