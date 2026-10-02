import type { RegistrationOperation } from "../../api/types";

export const setupStages = [
  { step: "ResolveBlueprint", label: "Prepare the blueprint", description: "Finding or creating the selected blueprint." },
  { step: "EnsureBlueprintPrincipal", label: "Enable the blueprint identity", description: "Preparing the blueprint's service principal." },
  { step: "ConfigureGatewayFederation", label: "Connect the Gateway", description: "Establishing the Gateway's secure connection to the blueprint." },
  { step: "CreateAgentIdentity", label: "Create the agent identity", description: "Creating this agent's own child identity." },
  { step: "AssignAgent365Access", label: "Assign Agent 365 access", description: "Configuring the agent identity's required access." },
  { step: "RegisterAgent", label: "Add to Microsoft 365 Registry", description: "Registering the existing agent identity with Microsoft 365." },
  { step: "VerifyAgent365Connection", label: "Verify the connection", description: "The worker checks the real Agent 365 connection before the agent becomes Active." },
] as const;

export function setupStageName(step: string | null | undefined): string {
  return setupStages.find(stage => stage.step === step)?.label ?? step ?? "Waiting for a reported stage";
}

export function isSupportedSetup(operation: RegistrationOperation): boolean {
  return ["ProvisionAgent", "RetryProvisioning"].includes(operation.type) &&
    operation.legacy !== true && (operation.workflowVersion === undefined || operation.workflowVersion === 3) &&
    ["Pending", "Running", "AwaitingAdministratorAction", "Completed", "Failed", "RequiresManualIntervention"].includes(operation.status) &&
    operation.steps?.length === setupStages.length &&
    operation.steps.every((step, index) => step.step === setupStages[index].step &&
      ["Pending", "Running", "Completed", "Skipped", "Failed"].includes(step.status)) &&
    (operation.currentStep === null || setupStages.some(stage => stage.step === operation.currentStep));
}
