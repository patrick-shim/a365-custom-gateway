using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Microsoft.Extensions.Options;

namespace Gateway.Api.Options;

public sealed class DelegatedRegistryActionGate
{
    private const string ClosedMessage =
        "Delegated Agent 365 Registry completion is unavailable because its administrator action gate is closed for this deployment.";

    private readonly Agent365DelegatedRegistryOptions _options;

    public DelegatedRegistryActionGate(IOptions<Agent365DelegatedRegistryOptions> options)
    {
        _options = options.Value;
    }

    public bool IsOpen =>
        _options.Enabled &&
        _options.AllowContinuousDevelopmentAccess;

    public void EnsureOpen()
    {
        if (IsOpen)
        {
            return;
        }

        throw new DomainException(ClosedMessage, ErrorCodes.PROVISIONING_DISABLED);
    }
}
