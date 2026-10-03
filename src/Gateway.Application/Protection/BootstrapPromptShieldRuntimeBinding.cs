using Gateway.Domain.Entities;

namespace Gateway.Application.Protection;

public interface IBootstrapPromptShieldRuntimeBinding
{
    bool IsExact(ProtectionCapability? capability);

    /// <summary>
    /// Portable ApiKey auth is ready without Azure managed-identity capability attestation.
    /// </summary>
    bool IsApiKeyRuntimeReady();
}
