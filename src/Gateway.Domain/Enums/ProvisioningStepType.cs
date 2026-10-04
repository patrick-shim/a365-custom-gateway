namespace Gateway.Domain.Enums;

public enum ProvisioningStepType
{
    ResolveBlueprint,
    EnsureBlueprintPrincipal,
    ConfigureGatewayFederation,
    CreateAgentIdentity,
    AssignAgent365Access,
    RegisterAgent,
    VerifyAgent365Connection
}
