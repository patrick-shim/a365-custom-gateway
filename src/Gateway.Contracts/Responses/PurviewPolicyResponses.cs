namespace Gateway.Contracts.Responses;

public sealed record PolicyCompatibilityResponse(bool CanAssign, string? Reason);
public sealed record PurviewPolicyResponse(Guid Id, string DisplayName, string Mode,
    string[] EnforcementPlanes, Guid[] IndividualApplicationIds, string Revision,
    PolicyCompatibilityResponse Compatibility);
public sealed record PurviewPolicyCatalogResponse(Guid TenantId, DateTimeOffset RetrievedAtUtc,
    string Source, IEnumerable<PurviewPolicyResponse> Items);
public sealed record AgentPolicyAssignmentResponse(Guid OperationId, Guid PolicyId, string PolicyName,
    string Status, string? FailureCode, DateTime? ConfirmedAtUtc, DateTime ExpiresAtUtc, DateTime? AssignedAtUtc);
public sealed record AgentPolicyAssignmentsResponse(Guid AgentId, string? AgentIdentityId, bool BindingCurrent,
    DateTime? AllowObservedAtUtc, DateTime? BlockObservedAtUtc, IEnumerable<AgentPolicyAssignmentResponse> Items);
public sealed record PolicyAssignmentReviewResponse(Guid OperationId, Guid AgentId, Guid AgentIdentityId,
    Guid PolicyId, string PolicyName, DateTime ExpiresAtUtc, string Effect);
public sealed record PolicyAssignmentConfirmationResponse(Guid OperationId, string Status);
