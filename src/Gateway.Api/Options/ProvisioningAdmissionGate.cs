using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Microsoft.Extensions.Options;

namespace Gateway.Api.Options;

public sealed class ProvisioningAdmissionGate
{
    private const string ClosedMessage =
        "Agent registration and provisioning retry are unavailable because the provisioning admission gate is closed for this deployment. Ask an operator to verify the deployment configuration.";

    private readonly ProvisioningOptions _options;

    public ProvisioningAdmissionGate(IOptions<ProvisioningOptions> options)
    {
        _options = options.Value;
    }

    public bool IsOpen => IsRegistrationOpen;

    public bool IsRegistrationOpen =>
        _options.ExecutionEnabled &&
        _options.AllowContinuousDevelopmentAccess;

    public void EnsureRegistrationOpen()
    {
        if (IsRegistrationOpen)
        {
            return;
        }

        throw new DomainException(ClosedMessage, ErrorCodes.PROVISIONING_DISABLED);
    }

    public void EnsureRetryOpen()
    {
        if (IsRegistrationOpen)
        {
            return;
        }

        throw new DomainException(ClosedMessage, ErrorCodes.PROVISIONING_DISABLED);
    }
}
