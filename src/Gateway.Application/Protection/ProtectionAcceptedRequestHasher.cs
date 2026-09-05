using System.Security.Cryptography;
using System.Text.Json;
using Gateway.Application.Configuration.Commands;
using Gateway.Contracts.Requests;

namespace Gateway.Application.Protection;

internal static class ProtectionAcceptedRequestHasher
{
    public static string Compute(
        StartPurviewTenantConnectionOperationRequest request) =>
        ComputeCore(new
        {
            operation = "StartPurviewTenantConnection",
            request.TenantId,
            request.ConfirmationTokenId,
            request.ConfirmationToken,
            request.IdempotencyKey,
            request.ExpectedRowVersion
        });

    public static string Compute(
        Guid operationId,
        CompletePurviewTenantConnectionOperationRequest request) =>
        ComputeCore(new
        {
            operation = "CompletePurviewTenantConnection",
            operationId,
            request.ConfirmationTokenId,
            request.ConfirmationToken,
            request.IdempotencyKey,
            request.ExpectedRowVersion,
            request.InventoryGenerationId,
            request.EvidenceDigest,
            evidence = new
            {
                request.Evidence.TenantId,
                request.Evidence.AdministratorObjectId,
                authorizedCapabilities =
                    request.Evidence.AuthorizedCapabilities.ToArray(),
                request.Evidence.ObservedAtUtc,
                request.Evidence.InventoryExpiresAtUtc,
                sensitiveInformationTypes =
                    request.Evidence.SensitiveInformationTypes
                        .OrderBy(item => item.ExactName, StringComparer.Ordinal)
                        .ThenBy(item => item.Id)
                        .Select(item => new
                        {
                            item.Id,
                            item.ExactName,
                            item.Publisher
                        })
                        .ToArray()
            }
        });

    public static string Compute(
        StartPurviewKnowYourDataOperationRequest request) =>
        ComputeMutation("StartPurviewKnowYourData", request);

    public static string Compute(
        StartPurviewDlpProfileOperationRequest request) =>
        ComputeMutation("StartPurviewDlpProfile", request);

    public static string Compute(
        Guid profileId,
        ReconcilePurviewDlpProfileRequest request) =>
        ComputeMutation("ReconcilePurviewDlpProfile", request, profileId);

    public static string Compute(
        Guid profileId,
        ValidatePurviewDlpProfileRuntimeRequest request) =>
        ComputeMutation("ValidatePurviewDlpProfileRuntime", request, profileId);

    public static string Compute(UpdateSystemConfigCommand request) =>
        ComputeCore(new
        {
            operation = "UpdateProtectionDefaults",
            request.ProvisioningMode,
            request.DefaultObservabilityMode,
            request.DefaultPurviewEnabled,
            request.DefaultPurviewMode,
            request.RetentionDaysActivityReceipts,
            request.RetentionDaysAuditEvents,
            request.RetentionDaysIdempotencyRecords,
            request.RetentionDaysOutboxMessages,
            request.RateLimitPerClient,
            request.RateLimitPerAgent,
            request.RateLimitGlobal,
            request.ReconciliationEnabled,
            request.ReconciliationIntervalHours,
            request.StuckTransitionTimeoutDays,
            request.UseGraphAgentRegistration,
            request.UseCliProvisioningFallback,
            request.DefaultAgent365ObservabilityEnabled,
            request.DefaultAzureMonitorExportEnabled,
            request.DefaultPromptShieldEnabled,
            request.ExpectedRowVersion
        });

    private static string ComputeMutation<T>(
        string operation,
        T request,
        Guid? profileId = null) =>
        ComputeCore(new
        {
            operation,
            profileId,
            request
        });

    private static string ComputeCore<T>(T payload)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(
            payload,
            ProtectionAdministrationRules.JsonOptions);
        try
        {
            return $"sha256:{Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant()}";
        }
        finally
        {
            CryptographicOperations.ZeroMemory(bytes);
        }
    }
}
