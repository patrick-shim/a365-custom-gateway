using System.Security.Cryptography;
using System.Text.Json;
using Gateway.Domain.Entities;

namespace Gateway.Provisioning.Worker;

internal static class ProtectionAdminIntentFingerprint
{
    private static readonly JsonSerializerOptions JsonOptions =
        new(JsonSerializerDefaults.Web);

    public static string ForConnection(Guid tenantId) =>
        Compute(new PurviewTenantConnectionPayload(tenantId));

    public static string ForKnowYourData(
        PurviewKnowYourDataConfiguration configuration) =>
        Compute(new PurviewKnowYourDataPayload(
            configuration.PurviewTenantConnectionId,
            configuration.InventoryGenerationId.Value,
            configuration.SensitiveInformationTypeId.Value,
            configuration.SensitiveInformationTypeName,
            configuration.Mode.ToString(),
            configuration.Activities
                .OrderBy(value => value)
                .Select(value => value.ToString())
                .ToArray(),
            configuration.IngestionEnabled));

    public static string ForDlpProfile(PurviewDlpProfile profile) =>
        Compute(new PurviewDlpProfilePayload(
            profile.Id.Value,
            profile.PurviewTenantConnectionId,
            profile.BlueprintApplicationId.Value,
            profile.DisplayName,
            profile.InventoryGenerationId.Value,
            profile.SensitiveInformationTypeId.Value,
            profile.SensitiveInformationTypeName,
            profile.Mode.ToString(),
            profile.Activities
                .OrderBy(value => value)
                .Select(value => value.ToString())
                .ToArray(),
            profile.Actions
                .OrderBy(value => value.Activity)
                .ThenBy(value => value.Action)
                .Select(value => new PurviewDlpRuleActionPayload(
                    value.Activity.ToString(),
                    value.Action.ToString()))
                .ToArray()));

    private static string Compute<T>(T payload)
    {
        var payloadBytes = JsonSerializer.SerializeToUtf8Bytes(payload, JsonOptions);
        try
        {
            return $"sha256:{Convert.ToHexString(SHA256.HashData(payloadBytes)).ToLowerInvariant()}";
        }
        finally
        {
            CryptographicOperations.ZeroMemory(payloadBytes);
        }
    }

    private sealed record PurviewTenantConnectionPayload(Guid TenantId);

    private sealed record PurviewKnowYourDataPayload(
        Guid TenantConnectionId,
        Guid InventoryGenerationId,
        Guid SensitiveInformationTypeId,
        string SensitiveInformationTypeName,
        string Mode,
        IReadOnlyList<string> Activities,
        bool IngestionEnabled);

    private sealed record PurviewDlpProfilePayload(
        Guid ProfileId,
        Guid TenantConnectionId,
        Guid BlueprintApplicationId,
        string DisplayName,
        Guid InventoryGenerationId,
        Guid SensitiveInformationTypeId,
        string SensitiveInformationTypeName,
        string Mode,
        IReadOnlyList<string> Activities,
        IReadOnlyList<PurviewDlpRuleActionPayload> Actions);

    private sealed record PurviewDlpRuleActionPayload(
        string Activity,
        string Action);
}
