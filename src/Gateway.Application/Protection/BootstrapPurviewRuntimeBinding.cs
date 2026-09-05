using Gateway.Domain.Entities;

namespace Gateway.Application.Protection;

public interface IBootstrapPurviewRuntimeBinding
{
    bool IsExact(ProtectionCapability? capability);
}
