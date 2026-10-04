using System.Security.Cryptography;
using System.Text.Json;
using Gateway.Application.Configuration.Commands;
using Gateway.Contracts.Requests;

namespace Gateway.Application.Protection;

internal static class ProtectionAcceptedRequestHasher
{
    public static string Compute(UpdateSystemConfigCommand request) =>
        ComputeCore(new
        {
            operation = "UpdateProtectionDefaults",
            request.DefaultObservabilityMode,
            request.RetentionDaysIdempotencyRecords,
            request.RateLimitPerClient,
            request.RateLimitPerAgent,
            request.RateLimitGlobal,
            request.DefaultAgent365ObservabilityEnabled,
            request.DefaultAzureMonitorExportEnabled,
            request.DefaultPromptShieldEnabled,
            request.ExpectedRowVersion
        });

    private static string ComputeCore<T>(T payload)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(
            payload,
            new JsonSerializerOptions(JsonSerializerDefaults.Web));
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
