using Gateway.Domain.Enums;

namespace Gateway.Domain.Models;

public static class ProvisioningWorkflow
{
    public const int LegacyVersion = 1;
    public const int CurrentVersion = 3;

    public static IReadOnlyList<ProvisioningStepType> CurrentSteps { get; } =
    [
        ProvisioningStepType.ResolveBlueprint,
        ProvisioningStepType.EnsureBlueprintPrincipal,
        ProvisioningStepType.ConfigureGatewayFederation,
        ProvisioningStepType.CreateAgentIdentity,
        ProvisioningStepType.AssignAgent365Access,
        ProvisioningStepType.RegisterAgent,
        ProvisioningStepType.VerifyAgent365Connection
    ];

    public static bool IsCurrent(
        int workflowVersion,
        IReadOnlyList<ProvisioningStepType> steps) =>
        workflowVersion == CurrentVersion && steps.SequenceEqual(CurrentSteps);
}
