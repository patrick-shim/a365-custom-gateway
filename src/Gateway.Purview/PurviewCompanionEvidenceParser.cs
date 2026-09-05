using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Gateway.Domain.Models;

namespace Gateway.Purview;

public static class PurviewCompanionEvidenceParser
{
    public const string ResultPrefix = "A365GW_CONNECTION_RESULT:";
    public const int MaximumOutputCharacters = 4 * 1024 * 1024;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        MaxDepth = 8,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    public static PurviewTenantConnectionCompanionEvidence Parse(string output)
    {
        if (string.IsNullOrWhiteSpace(output) ||
            output.Length > MaximumOutputCharacters)
        {
            throw InvalidEvidence();
        }

        var matches = output.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(line => line.Trim())
            .Where(line => line.StartsWith(ResultPrefix, StringComparison.Ordinal))
            .ToArray();
        if (matches.Length != 1)
            throw InvalidEvidence();

        try
        {
            var payload = Convert.FromBase64String(matches[0][ResultPrefix.Length..]);
            if (payload.Length > MaximumOutputCharacters)
                throw InvalidEvidence();

            return JsonSerializer.Deserialize<PurviewTenantConnectionCompanionEvidence>(
                       Encoding.UTF8.GetString(payload),
                       JsonOptions) ??
                   throw InvalidEvidence();
        }
        catch (Exception exception) when (
            exception is FormatException or
                JsonException or
                DecoderFallbackException)
        {
            throw new PurviewPolicyException(
                "PURVIEW_CONNECTION_EVIDENCE_INVALID",
                "The Purview companion returned invalid bounded typed evidence.",
                innerException: exception);
        }
    }

    private static PurviewPolicyException InvalidEvidence() =>
        new(
            "PURVIEW_CONNECTION_EVIDENCE_INVALID",
            "The Purview companion returned invalid bounded typed evidence.");
}

public static class PurviewCompanionCommand
{
    public const string ScriptFileName = "Connect-PurviewTenant.ps1";

    public static IReadOnlyList<string> CreateArguments(
        PurviewTenantConnectionOperationBinding binding)
    {
        ArgumentNullException.ThrowIfNull(binding);
        if (binding.OperationId == Guid.Empty ||
            binding.TenantId == Guid.Empty ||
            binding.AdministratorObjectId == Guid.Empty ||
            binding.InventoryGenerationId == Guid.Empty ||
            binding.ExpiresAtUtc.Offset != TimeSpan.Zero)
        {
            throw new PurviewPolicyException(
                "PURVIEW_CONNECTION_BINDING_INVALID",
                "The pending Purview connection operation binding is invalid.");
        }

        return
        [
            "-NoLogo",
            "-NoProfile",
            "-File",
            ScriptFileName,
            "-OperationId",
            binding.OperationId.ToString("D"),
            "-TenantId",
            binding.TenantId.ToString("D"),
            "-AdministratorObjectId",
            binding.AdministratorObjectId.ToString("D"),
            "-InventoryGenerationId",
            binding.InventoryGenerationId.ToString("D"),
            "-ExpiresAtUtc",
            binding.ExpiresAtUtc.ToString("O")
        ];
    }
}
