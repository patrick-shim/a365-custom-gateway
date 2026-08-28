namespace Gateway.Domain.Enums;

public enum ProvisioningStepType
{
    // Values 0-7 are persisted by the legacy workflow. Never reorder or reuse them.
    CreateAppRegistration = 0,
    CreateServicePrincipal = 1,
    AssignRoles = 2,
    StoreCredentials = 3,
    CreateBlueprint = 4,
    CreateBlueprintPrincipal = 5,
    CreateAgentIdentity = 6,
    RegisterAgent = 7,

    ResolveBlueprint = 8,
    EnsureBlueprintPrincipal = 9,
    ConfigureGatewayFederation = 10,
    AssignAgent365Access = 11,
    VerifyAgent365Connection = 12
}
