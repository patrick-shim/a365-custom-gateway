using System.Text.Json;
using Gateway.Contracts;
using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Models;

namespace Gateway.Application.Agents;

internal static class ProvisioningRetryPolicy
{
    private const string DirectRegistryPreviewProvider = "DirectRegistryPreview";
    private const string DelegatedAdministratorAuthenticationMode = "DelegatedAdministrator";
    private const string RetryGuardFailureSummary =
        "A prior provisioning result is ambiguous or requires manual reconciliation.";

    public static ProvisioningRetryDecision Evaluate(
        AgentStatus agentStatus,
        IReadOnlyCollection<ProvisioningJob> priorJobs)
    {
        if (agentStatus is not (AgentStatus.Failed or AgentStatus.RequiresManualIntervention))
        {
            return ProvisioningRetryDecision.Rejected(
                "Retry is available only after the Gateway confirms a safely retryable provisioning failure.",
                "RetryProvisioning");
        }

        var provisioningJobs = priorJobs
            .Where(existing =>
                existing.Type is OperationType.ProvisionAgent or OperationType.RetryProvisioning)
            .ToArray();
        if (provisioningJobs.Length == 0)
        {
            return RejectUnsafeRetry();
        }

        if (provisioningJobs.Any(existing => !ProvisioningWorkflow.IsCurrent(
                existing.WorkflowVersion,
                existing.Steps
                    .OrderBy(step => step.OrderIndex)
                    .Select(step => step.StepType)
                    .ToList())))
        {
            return ProvisioningRetryDecision.Rejected(
                "Retry is unavailable because this registration has non-replayable legacy provisioning history.",
                "RetryLegacyProvisioning");
        }

        if (provisioningJobs.Any(existing =>
                existing.Status is JobStatus.Pending or JobStatus.Running))
        {
            return ProvisioningRetryDecision.Rejected(
                "Retry is unavailable while another provisioning operation is pending or running.",
                "RetryProvisioningActiveJob");
        }

        var retryCandidates = provisioningJobs
            .Where(existing => !IsRetryGuardFailure(existing))
            .ToArray();
        if (retryCandidates.Length == 0)
        {
            return RejectUnsafeRetry();
        }

        if (provisioningJobs.Any(existing =>
                existing.Steps.Any(step => step.Status == StepStatus.Running)) ||
            retryCandidates.Any(existing =>
                string.Equals(
                    existing.ErrorCode,
                    ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                    StringComparison.Ordinal) ||
                existing.Steps.Any(step => string.Equals(
                    step.ErrorCode,
                    ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                    StringComparison.Ordinal))) ||
            retryCandidates.Any(HasUnsafeRegistryBoundary))
        {
            return RejectUnsafeRetry();
        }

        var latestJob = retryCandidates
            .OrderByDescending(existing => existing.CreatedAtUtc)
            .ThenByDescending(existing => existing.Id)
            .First();
        if (latestJob.Status is not (JobStatus.Failed or JobStatus.RequiresManualIntervention) ||
            string.IsNullOrWhiteSpace(latestJob.ErrorCode) ||
            !latestJob.Steps.Any(step => step.Status == StepStatus.Failed) ||
            !HasValidCompletedPrefix(latestJob))
        {
            return RejectUnsafeRetry();
        }

        return ProvisioningRetryDecision.Allowed(
            "The Gateway confirmed that the latest workflow-v3 failure is safely retryable from its verified completed prefix.",
            latestJob,
            latestJob.Steps.Count(step => step.Status == StepStatus.Completed));
    }

    private static bool IsRetryGuardFailure(ProvisioningJob job)
    {
        if (job.Type != OperationType.RetryProvisioning ||
            job.Status != JobStatus.RequiresManualIntervention ||
            !string.Equals(
                job.ErrorCode,
                ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                StringComparison.Ordinal) ||
            !string.Equals(job.ErrorSummary, RetryGuardFailureSummary, StringComparison.Ordinal))
        {
            return false;
        }

        var ordered = job.Steps.OrderBy(step => step.OrderIndex).ToArray();
        if (ordered.Length != ProvisioningWorkflow.CurrentSteps.Count ||
            ordered[^1].StepType != ProvisioningStepType.VerifyAgent365Connection ||
            ordered[^1].Status != StepStatus.Failed ||
            !string.Equals(
                ordered[^1].ErrorCode,
                ErrorCodes.PROVISIONING_AMBIGUOUS_RESULT,
                StringComparison.Ordinal) ||
            !string.Equals(ordered[^1].ErrorMessage, RetryGuardFailureSummary, StringComparison.Ordinal) ||
            ordered.Take(ordered.Length - 1).Any(step => step.Status != StepStatus.Completed))
        {
            return false;
        }

        return HasValidCompletedPrefix(job) && !HasUnsafeRegistryBoundary(job);
    }

    private static bool HasUnsafeRegistryBoundary(ProvisioningJob job)
    {
        var registryStep = job.Steps.Single(step =>
            step.StepType == ProvisioningStepType.RegisterAgent);
        if (registryStep.Status == StepStatus.Pending)
            return job.Status != JobStatus.Failed;

        if (registryStep.Status != StepStatus.Completed ||
            string.IsNullOrWhiteSpace(registryStep.ResultData))
        {
            return true;
        }

        try
        {
            var result = JsonSerializer.Deserialize<Agent365ProvisioningStepResult>(
                registryStep.ResultData);
            return result is null ||
                   result.State is null ||
                   result.StepType != ProvisioningStepType.RegisterAgent ||
                   !IsSafeCompletionEvidence(result.CompletionEvidence) ||
                   !TryParseNonEmptyGuid(
                       result.State.Agent365RegistrationId,
                       out _) ||
                   !string.Equals(
                       result.State.RegistryProvider,
                       DirectRegistryPreviewProvider,
                       StringComparison.Ordinal) ||
                   !string.Equals(
                       result.State.RegistryAuthenticationMode,
                       DelegatedAdministratorAuthenticationMode,
                       StringComparison.Ordinal) ||
                   !TryParseNonEmptyGuid(result.State.RegistryCreatedByObjectId, out _) ||
                   (result.State.Agent365RegistrationAcceptedAtUtc is null &&
                    result.State.Agent365RegistrationVerifiedAtUtc is null);
        }
        catch (JsonException)
        {
            return true;
        }
    }

    private static bool HasValidCompletedPrefix(ProvisioningJob job)
    {
        var state = new Agent365ProvisioningState();
        var sawIncompleteStep = false;

        foreach (var step in job.Steps.OrderBy(step => step.OrderIndex))
        {
            if (step.Status != StepStatus.Completed)
            {
                sawIncompleteStep = true;
                continue;
            }

            if (sawIncompleteStep ||
                !TryDeserializeStepResult(step, out var result) ||
                !StatePreserves(state, result.State) ||
                !IsStepComplete(step.StepType, result.State))
            {
                return false;
            }

            state = result.State;
        }

        return true;
    }

    private static bool TryDeserializeStepResult(
        ProvisioningJobStep step,
        out Agent365ProvisioningStepResult result)
    {
        result = null!;
        if (string.IsNullOrWhiteSpace(step.ResultData))
            return false;

        try
        {
            var parsed = JsonSerializer.Deserialize<Agent365ProvisioningStepResult>(
                step.ResultData);
            if (parsed is null ||
                parsed.State is null ||
                parsed.StepType != step.StepType ||
                !IsSafeCompletionEvidence(parsed.CompletionEvidence))
            {
                return false;
            }

            result = parsed;
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static bool IsStepComplete(
        ProvisioningStepType stepType,
        Agent365ProvisioningState state)
    {
        return stepType switch
        {
            ProvisioningStepType.ResolveBlueprint =>
                HasValue(state.BlueprintObjectId) &&
                HasValue(state.BlueprintClientId),
            ProvisioningStepType.EnsureBlueprintPrincipal =>
                HasValue(state.BlueprintPrincipalObjectId),
            ProvisioningStepType.ConfigureGatewayFederation =>
                HasValue(state.GatewayManagedIdentityPrincipalId) &&
                HasValue(state.GatewayFederatedCredentialId),
            ProvisioningStepType.CreateAgentIdentity =>
                HasValue(state.AgentIdentityObjectId) &&
                HasValue(state.AgentIdentityClientId) &&
                HasValue(state.BlueprintClientId),
            ProvisioningStepType.AssignAgent365Access =>
                HasValue(state.ObservabilityAppRoleAssignmentId) &&
                HasValue(state.AgentIdentityClientId),
            ProvisioningStepType.RegisterAgent =>
                HasValue(state.Agent365RegistrationId) &&
                string.Equals(
                    state.RegistryProvider,
                    DirectRegistryPreviewProvider,
                    StringComparison.Ordinal) &&
                string.Equals(
                    state.RegistryAuthenticationMode,
                    DelegatedAdministratorAuthenticationMode,
                    StringComparison.Ordinal) &&
                TryParseNonEmptyGuid(state.RegistryCreatedByObjectId, out _) &&
                   (state.Agent365RegistrationAcceptedAtUtc is not null ||
                    state.Agent365RegistrationVerifiedAtUtc is not null),
            ProvisioningStepType.VerifyAgent365Connection =>
                state.Agent365ConnectionVerifiedAtUtc is not null &&
                HasValue(state.BlueprintPrincipalObjectId) &&
                HasValue(state.GatewayManagedIdentityPrincipalId) &&
                HasValue(state.GatewayFederatedCredentialId) &&
                HasValue(state.AgentIdentityClientId) &&
                HasValue(state.BlueprintClientId) &&
                HasValue(state.ObservabilityAppRoleAssignmentId) &&
                HasValue(state.Agent365RegistrationId),
            _ => false
        };
    }

    private static bool StatePreserves(
        Agent365ProvisioningState previous,
        Agent365ProvisioningState current)
    {
        return Preserves(previous.ApplicationObjectId, current.ApplicationObjectId) &&
               Preserves(previous.ApplicationClientId, current.ApplicationClientId) &&
               Preserves(previous.ServicePrincipalObjectId, current.ServicePrincipalObjectId) &&
               Preserves(previous.AppRoleAssignmentId, current.AppRoleAssignmentId) &&
               Preserves(previous.PasswordCredentialKeyId, current.PasswordCredentialKeyId) &&
               Preserves(previous.KeyVaultSecretUri, current.KeyVaultSecretUri) &&
               Preserves(previous.CredentialExpiresAtUtc, current.CredentialExpiresAtUtc) &&
               Preserves(previous.BlueprintObjectId, current.BlueprintObjectId) &&
               Preserves(previous.BlueprintClientId, current.BlueprintClientId) &&
               Preserves(previous.BlueprintPrincipalObjectId, current.BlueprintPrincipalObjectId) &&
               Preserves(previous.AgentIdentityObjectId, current.AgentIdentityObjectId) &&
               Preserves(previous.AgentIdentityClientId, current.AgentIdentityClientId) &&
               Preserves(previous.ObservabilityAppRoleAssignmentId, current.ObservabilityAppRoleAssignmentId) &&
               Preserves(previous.GatewayManagedIdentityPrincipalId, current.GatewayManagedIdentityPrincipalId) &&
               Preserves(previous.GatewayFederatedCredentialId, current.GatewayFederatedCredentialId) &&
               Preserves(previous.PlannedAgent365RegistrationId, current.PlannedAgent365RegistrationId) &&
               Preserves(previous.Agent365RegistrationId, current.Agent365RegistrationId) &&
               Preserves(previous.RegistryProvider, current.RegistryProvider) &&
               Preserves(previous.RegistryAuthenticationMode, current.RegistryAuthenticationMode) &&
               Preserves(previous.RegistryCreatedByObjectId, current.RegistryCreatedByObjectId) &&
               Preserves(
                   previous.Agent365RegistrationAcceptedAtUtc,
                   current.Agent365RegistrationAcceptedAtUtc) &&
               Preserves(
                   previous.Agent365RegistrationVerifiedAtUtc,
                   current.Agent365RegistrationVerifiedAtUtc) &&
               Preserves(
                   previous.Agent365ConnectionVerifiedAtUtc,
                   current.Agent365ConnectionVerifiedAtUtc);
    }

    private static bool Preserves(string? previous, string? current) =>
        previous is null || string.Equals(previous, current, StringComparison.Ordinal);

    private static bool Preserves(DateTimeOffset? previous, DateTimeOffset? current) =>
        previous is null || previous == current;

    private static bool HasValue(string? value) => !string.IsNullOrWhiteSpace(value);

    private static bool TryParseNonEmptyGuid(string? value, out Guid parsed) =>
        Guid.TryParse(value, out parsed) && parsed != Guid.Empty;

    private static bool IsSafeCompletionEvidence(string? evidence) =>
        !string.IsNullOrWhiteSpace(evidence) &&
        evidence.Length <= 64 &&
        evidence.All(character =>
            char.IsLetterOrDigit(character) || character is '-' or '_');

    private static ProvisioningRetryDecision RejectUnsafeRetry() =>
        ProvisioningRetryDecision.Rejected(
            "Retry is unavailable because the provisioning history is ambiguous or lacks durable retry-safe failure evidence. Reconcile Microsoft resource state manually.",
            "RetryUnsafeProvisioningFailure");
}

internal sealed record ProvisioningRetryDecision(
    bool Supported,
    string SafeReason,
    string? RejectedAction,
    ProvisioningJob? SourceJob,
    int ResumeStepIndex)
{
    public static ProvisioningRetryDecision Allowed(
        string safeReason,
        ProvisioningJob sourceJob,
        int resumeStepIndex) =>
        new(true, safeReason, null, sourceJob, resumeStepIndex);

    public static ProvisioningRetryDecision Rejected(string safeReason, string rejectedAction) =>
        new(false, safeReason, rejectedAction, null, 0);
}
