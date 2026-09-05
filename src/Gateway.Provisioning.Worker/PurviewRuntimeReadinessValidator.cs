using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.Interfaces;
using Gateway.Domain.Models;

namespace Gateway.Provisioning.Worker;

internal enum PurviewRuntimeValidationStatus
{
    Ready,
    Pending,
    Failed,
    Unsupported,
    OutcomeUnknown
}

internal sealed record PurviewRuntimeValidationResult(
    PurviewRuntimeValidationStatus Status,
    DateTimeOffset ObservedAtUtc,
    string? FailureCode)
{
    public static PurviewRuntimeValidationResult Ready(DateTime utcNow) =>
        Ready(new DateTimeOffset(utcNow, TimeSpan.Zero));

    public static PurviewRuntimeValidationResult Ready(DateTimeOffset observedAtUtc) =>
        new(PurviewRuntimeValidationStatus.Ready, observedAtUtc, null);

    public static PurviewRuntimeValidationResult Pending(
        DateTimeOffset observedAtUtc,
        string failureCode) =>
        new(PurviewRuntimeValidationStatus.Pending, observedAtUtc, failureCode);

    public static PurviewRuntimeValidationResult Failed(
        DateTimeOffset observedAtUtc,
        string failureCode) =>
        new(PurviewRuntimeValidationStatus.Failed, observedAtUtc, failureCode);

    public static PurviewRuntimeValidationResult Unsupported(
        DateTimeOffset observedAtUtc,
        string failureCode) =>
        new(PurviewRuntimeValidationStatus.Unsupported, observedAtUtc, failureCode);

    public static PurviewRuntimeValidationResult OutcomeUnknown(
        DateTimeOffset observedAtUtc,
        string failureCode) =>
        new(PurviewRuntimeValidationStatus.OutcomeUnknown, observedAtUtc, failureCode);
}

internal interface IPurviewRuntimeReadinessValidator
{
    Task<PurviewRuntimeValidationResult> ProbePropagationAsync(
        Guid operationId,
        string administratorObjectId,
        PurviewDlpProfile profile,
        CancellationToken ct);

    Task<PurviewRuntimeValidationResult> ValidateAllowAsync(
        Guid operationId,
        string administratorObjectId,
        PurviewDlpProfile profile,
        CancellationToken ct);

    Task<PurviewRuntimeValidationResult> ValidateBlockAsync(
        Guid operationId,
        string administratorObjectId,
        PurviewDlpProfile profile,
        CancellationToken ct);
}

internal sealed class PurviewRuntimeReadinessValidator : IPurviewRuntimeReadinessValidator
{
    private const int MaximumActiveRegistrationsToInspect = 1000;
    private const string BenignValidationInput =
        "A365 Gateway synthetic benign readiness validation.";
    private const string SensitiveValidationInput =
        "A365 Gateway approved synthetic card 4111 1111 1111 1111.";

    private readonly IAgentRepository _agentRepository;
    private readonly IPurviewPolicyClient _policyClient;

    public PurviewRuntimeReadinessValidator(
        IAgentRepository agentRepository,
        IPurviewPolicyClient policyClient)
    {
        _agentRepository = agentRepository;
        _policyClient = policyClient;
    }

    public Task<PurviewRuntimeValidationResult> ProbePropagationAsync(
        Guid operationId,
        string administratorObjectId,
        PurviewDlpProfile profile,
        CancellationToken ct) =>
        EvaluateAsync(
            operationId,
            administratorObjectId,
            profile,
            "propagation",
            BenignValidationInput,
            expectAllowed: true,
            propagationProbe: true,
            ct);

    public Task<PurviewRuntimeValidationResult> ValidateAllowAsync(
        Guid operationId,
        string administratorObjectId,
        PurviewDlpProfile profile,
        CancellationToken ct) =>
        EvaluateAsync(
            operationId,
            administratorObjectId,
            profile,
            "allow",
            BenignValidationInput,
            expectAllowed: true,
            propagationProbe: false,
            ct);

    public Task<PurviewRuntimeValidationResult> ValidateBlockAsync(
        Guid operationId,
        string administratorObjectId,
        PurviewDlpProfile profile,
        CancellationToken ct) =>
        EvaluateAsync(
            operationId,
            administratorObjectId,
            profile,
            "block",
            SensitiveValidationInput,
            expectAllowed: false,
            propagationProbe: false,
            ct);

    private async Task<PurviewRuntimeValidationResult> EvaluateAsync(
        Guid operationId,
        string administratorObjectId,
        PurviewDlpProfile profile,
        string validationKind,
        string validationInput,
        bool expectAllowed,
        bool propagationProbe,
        CancellationToken ct)
    {
        var observedAtUtc = DateTimeOffset.UtcNow;
        if (!_policyClient.IsEnabled)
        {
            return PurviewRuntimeValidationResult.Unsupported(
                observedAtUtc,
                "PURVIEW_RUNTIME_NOT_CONFIGURED");
        }

        if (operationId == Guid.Empty ||
            !Guid.TryParse(administratorObjectId, out var administratorId) ||
            administratorId == Guid.Empty ||
            profile.Id.Value == Guid.Empty ||
            profile.BlueprintApplicationId.Value == Guid.Empty)
        {
            return PurviewRuntimeValidationResult.Failed(
                observedAtUtc,
                "PURVIEW_RUNTIME_IDENTITY_INVALID");
        }

        var runtimeAgent = await FindRuntimeAgentAsync(profile, ct);
        if (runtimeAgent is null)
        {
            return PurviewRuntimeValidationResult.Failed(
                observedAtUtc,
                "PURVIEW_RUNTIME_AGENT_NOT_DISCOVERABLE");
        }

        try
        {
            var interaction = new PurviewInteraction(
                runtimeAgent.Id,
                administratorObjectId,
                $"{operationId:D}:{validationKind}",
                validationInput,
                "text/plain",
                string.Empty,
                "text/plain",
                ModelProvider: null,
                ModelName: null,
                runtimeAgent.Agent365AgentId!,
                profile.BlueprintApplicationId.Value.ToString("D"),
                runtimeAgent.Name,
                observedAtUtc.UtcDateTime,
                PurviewExecutionMode.EvaluateInline,
                operationId.ToString("D"));
            var verdict = await _policyClient.EvaluatePromptAsync(interaction, ct);
            var exact = expectAllowed
                ? verdict.IsAllowed && verdict.Decision == PurviewDecisionType.Allowed
                : !verdict.IsAllowed && verdict.Decision == PurviewDecisionType.Blocked;
            if (exact)
                return PurviewRuntimeValidationResult.Ready(DateTimeOffset.UtcNow);

            return PurviewRuntimeValidationResult.Failed(
                DateTimeOffset.UtcNow,
                expectAllowed
                    ? "PURVIEW_RUNTIME_ALLOW_NOT_OBSERVED"
                    : "PURVIEW_RUNTIME_BLOCK_NOT_OBSERVED");
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (PurviewPolicyException exception) when (
            propagationProbe &&
            exception.IsTransient &&
            IsKnownPreDecisionPropagationState(exception.FailureCode))
        {
            return PurviewRuntimeValidationResult.Pending(
                DateTimeOffset.UtcNow,
                exception.FailureCode);
        }
        catch (PurviewPolicyException exception)
        {
            return PurviewRuntimeValidationResult.OutcomeUnknown(
                DateTimeOffset.UtcNow,
                SafeFailureCode(exception.FailureCode));
        }
        catch (Exception)
        {
            return PurviewRuntimeValidationResult.OutcomeUnknown(
                DateTimeOffset.UtcNow,
                "PURVIEW_RUNTIME_OUTCOME_UNKNOWN");
        }
    }

    private async Task<AgentRegistration?> FindRuntimeAgentAsync(
        PurviewDlpProfile profile,
        CancellationToken ct)
    {
        var (items, totalCount) = await _agentRepository.ListAsync(
            new AgentListFilter(
                AgentStatus.Active.ToString(),
                Environment: null,
                Search: null,
                MaximumActiveRegistrationsToInspect,
                Cursor: null),
            ct);
        var expectedBlueprint = profile.BlueprintApplicationId.Value.ToString("D");
        var match = items
            .Where(agent =>
                !agent.IsDeleted &&
                string.Equals(agent.BlueprintId, expectedBlueprint, StringComparison.Ordinal) &&
                Guid.TryParse(agent.Agent365AgentId, out var childClientId) &&
                childClientId != Guid.Empty)
            .OrderBy(agent => agent.Id)
            .FirstOrDefault();
        if (match is null && totalCount > items.Count)
            return null;

        return match;
    }

    private static bool IsKnownPreDecisionPropagationState(string failureCode) =>
        failureCode is "PURVIEW_SCOPE_MISSING" or "PURVIEW_SCOPE_INVALID_STATUS";

    private static string SafeFailureCode(string value) =>
        IsSafeFailureCode(value)
            ? value
            : "PURVIEW_RUNTIME_OUTCOME_UNKNOWN";

    private static bool IsSafeFailureCode(string? value) =>
        !string.IsNullOrWhiteSpace(value) &&
        value.Length <= 64 &&
        value.All(character =>
            character is >= 'A' and <= 'Z' or >= '0' and <= '9' or '_');
}
