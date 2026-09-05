using Gateway.Domain.Entities;

namespace Gateway.Application.Protection;

public interface IBootstrapPromptShieldRuntimeBinding
{
    bool IsExact(ProtectionCapability? capability);
}
