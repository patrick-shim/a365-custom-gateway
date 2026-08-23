namespace Gateway.Domain.Enums;

public enum ProvisioningStepType
{
    CreateAppRegistration,
    CreateServicePrincipal,
    AssignRoles,
    StoreCredentials,
    CreateBlueprint,
    CreateBlueprintPrincipal,
    RegisterAgent
}
