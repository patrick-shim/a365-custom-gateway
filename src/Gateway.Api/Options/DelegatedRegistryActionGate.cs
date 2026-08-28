using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Microsoft.Extensions.Options;

namespace Gateway.Api.Options;

public sealed class DelegatedRegistryActionGate
{
    private const string ClosedMessage =
        "Delegated Agent 365 Registry completion is unavailable because its bounded administrator-action gate is closed for this operation.";

    private readonly Agent365DelegatedRegistryOptions _options;
    private readonly TimeProvider _timeProvider;

    public DelegatedRegistryActionGate(
        IOptions<Agent365DelegatedRegistryOptions> options,
        TimeProvider timeProvider)
    {
        _options = options.Value;
        _timeProvider = timeProvider;
    }

    public bool IsOpen(Guid operationId) =>
        _options.Enabled &&
        (_options.AllowContinuousDevelopmentAccess ||
         (ProvisioningAdmissionGate.TryParseUtcExpiry(
              _options.ActionExpiresAtUtc,
              out var expiresAtUtc) &&
          expiresAtUtc > _timeProvider.GetUtcNow())) &&
        (_options.AllowContinuousDevelopmentAccess ||
         !_options.RequireExactActionBinding ||
         (Guid.TryParse(_options.AuthorizedOperationId, out var authorizedOperationId) &&
          authorizedOperationId == operationId));

    public void EnsureOpen(Guid operationId)
    {
        if (IsOpen(operationId))
        {
            return;
        }

        throw new DomainException(ClosedMessage, ErrorCodes.PROVISIONING_DISABLED);
    }
}
