using System.Text.RegularExpressions;
using Microsoft.Extensions.Options;

namespace Gateway.Infrastructure.Persistence;

public sealed class DatabaseAttestationOptions
{
    public const string SectionName = "DatabaseAttestation";

    public bool Enabled { get; set; }

    public string DeploymentOwnershipId { get; set; } = string.Empty;

    public string AcceptedSourceFingerprint { get; set; } = string.Empty;

    public string ExpectedSchemaFingerprint { get; set; } = string.Empty;

    public string SqlServerFqdn { get; set; } = string.Empty;

    public string DatabaseName { get; set; } = string.Empty;

    public string ApiPrincipalName { get; set; } = string.Empty;

    public string ApiPrincipalClientId { get; set; } = string.Empty;

    public string WorkerPrincipalName { get; set; } = string.Empty;

    public string WorkerPrincipalClientId { get; set; } = string.Empty;
}

internal sealed partial class DatabaseAttestationOptionsValidator
    : IValidateOptions<DatabaseAttestationOptions>
{
    public ValidateOptionsResult Validate(
        string? name,
        DatabaseAttestationOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (!options.Enabled)
            return ValidateOptionsResult.Success;

        if (!TryCanonicalGuid(options.DeploymentOwnershipId) ||
            !FingerprintPattern().IsMatch(options.AcceptedSourceFingerprint) ||
            !FingerprintPattern().IsMatch(options.ExpectedSchemaFingerprint) ||
            !SqlServerPattern().IsMatch(options.SqlServerFqdn) ||
            !options.DatabaseName.Equals("GatewayDb", StringComparison.Ordinal) ||
            !PrincipalNamePattern().IsMatch(options.ApiPrincipalName) ||
            !PrincipalNamePattern().IsMatch(options.WorkerPrincipalName) ||
            options.ApiPrincipalName.Equals(options.WorkerPrincipalName, StringComparison.Ordinal) ||
            !TryCanonicalGuid(options.ApiPrincipalClientId) ||
            !TryCanonicalGuid(options.WorkerPrincipalClientId) ||
            options.ApiPrincipalClientId.Equals(options.WorkerPrincipalClientId, StringComparison.Ordinal))
        {
            return ValidateOptionsResult.Fail(
                "Database attestation requires one exact bootstrap ownership/source/schema and two distinct canonical runtime principals.");
        }

        return ValidateOptionsResult.Success;
    }

    private static bool TryCanonicalGuid(string value) =>
        Guid.TryParseExact(value, "D", out var parsed) &&
        parsed != Guid.Empty &&
        value.Equals(parsed.ToString("D"), StringComparison.Ordinal);

    [GeneratedRegex("^sha256:[0-9a-f]{64}$", RegexOptions.CultureInvariant)]
    private static partial Regex FingerprintPattern();

    [GeneratedRegex("^[A-Za-z0-9-]+\\.database\\.windows\\.net$", RegexOptions.CultureInvariant)]
    private static partial Regex SqlServerPattern();

    [GeneratedRegex("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", RegexOptions.CultureInvariant)]
    private static partial Regex PrincipalNamePattern();
}
