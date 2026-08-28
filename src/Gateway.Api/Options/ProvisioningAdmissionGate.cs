using System.Globalization;
using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Microsoft.Extensions.Options;

namespace Gateway.Api.Options;

public sealed class ProvisioningAdmissionGate
{
    private const string ClosedMessage =
        "Agent registration and provisioning retry are temporarily unavailable because the provisioning admission gate is closed for this deployment. Ask an operator to complete the provisioning preflight and open a bounded admission window.";

    private readonly ProvisioningOptions _options;
    private readonly TimeProvider _timeProvider;

    public ProvisioningAdmissionGate(
        IOptions<ProvisioningOptions> options,
        TimeProvider timeProvider)
    {
        _options = options.Value;
        _timeProvider = timeProvider;
    }

    public bool IsOpen => IsRegistrationOpen;

    public string? AuthorizedRegistrationExternalAgentId =>
        IsRegistrationOpen && _options.RequireExactAdmissionBinding
            ? _options.AuthorizedExternalAgentId
            : null;

    public bool IsRegistrationOpen =>
        IsWindowOpen &&
        (_options.AllowContinuousDevelopmentAccess ||
         !_options.RequireExactAdmissionBinding ||
         !string.IsNullOrWhiteSpace(_options.AuthorizedExternalAgentId));

    private bool IsWindowOpen =>
        _options.ExecutionEnabled &&
        (_options.AllowContinuousDevelopmentAccess ||
         (TryParseUtcExpiry(_options.AdmissionExpiresAtUtc, out var expiresAtUtc) &&
          expiresAtUtc > _timeProvider.GetUtcNow()));

    public void EnsureRegistrationOpen(string externalAgentId)
    {
        if (IsRegistrationOpen &&
            (_options.AllowContinuousDevelopmentAccess ||
             !_options.RequireExactAdmissionBinding ||
             string.Equals(
                 externalAgentId,
                 _options.AuthorizedExternalAgentId,
                 StringComparison.Ordinal)))
        {
            return;
        }

        throw new DomainException(ClosedMessage, ErrorCodes.PROVISIONING_DISABLED);
    }

    public void EnsureRetryOpen(Guid agentId)
    {
        if (IsWindowOpen &&
            (_options.AllowContinuousDevelopmentAccess ||
             !_options.RequireExactAdmissionBinding ||
             (Guid.TryParse(_options.AuthorizedRetryAgentId, out var authorizedAgentId) &&
              authorizedAgentId == agentId)))
        {
            return;
        }

        throw new DomainException(ClosedMessage, ErrorCodes.PROVISIONING_DISABLED);
    }

    internal static bool TryParseUtcExpiry(
        string? value,
        out DateTimeOffset expiresAtUtc)
    {
        expiresAtUtc = default;
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        var candidate = value.Trim();
        if (!HasExplicitUtcDesignator(candidate) ||
            !DateTimeOffset.TryParse(
                candidate,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AllowWhiteSpaces,
                out var parsed) ||
            parsed.Offset != TimeSpan.Zero)
        {
            return false;
        }

        expiresAtUtc = parsed;
        return true;
    }

    private static bool HasExplicitUtcDesignator(string value) =>
        value.EndsWith("Z", StringComparison.OrdinalIgnoreCase) ||
        value.EndsWith("+00", StringComparison.Ordinal) ||
        value.EndsWith("+0000", StringComparison.Ordinal) ||
        value.EndsWith("+00:00", StringComparison.Ordinal);
}
