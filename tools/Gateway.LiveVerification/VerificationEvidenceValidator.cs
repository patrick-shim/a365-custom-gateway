namespace Gateway.LiveVerification;

internal static class VerificationEvidenceValidator
{
    private static readonly HashSet<string> NonBlockingPurviewDecisions = new(StringComparer.Ordinal)
    {
        "Allowed",
        "AuditOnly",
        "AuditLogged"
    };

    internal static void ValidateIssuedCredential(
        IssueCredentialResponse response,
        Guid expectedAgentRegistrationId,
        string expectedExternalAgentId)
    {
        if (response.AgentId != expectedAgentRegistrationId
            || !string.Equals(response.ExternalAgentId, expectedExternalAgentId, StringComparison.Ordinal)
            || response.GatewayCredential.KeyId == Guid.Empty
            || string.IsNullOrWhiteSpace(response.GatewayCredential.ApiKey))
        {
            throw new InvalidOperationException(
                "Temporary credential issuance returned invalid registration-bound data.");
        }
    }

    internal static void ValidateRevokedCredential(
        RevokeCredentialResponse response,
        Guid expectedAgentRegistrationId,
        Guid expectedCredentialId)
    {
        if (response.AgentId != expectedAgentRegistrationId
            || response.Credential.KeyId != expectedCredentialId
            || response.Credential.RevokedAtUtc is null)
        {
            throw new InvalidOperationException(
                "Temporary credential revocation did not prove the exact registration-bound key lifecycle.");
        }
    }

    internal static PromptEvaluation ValidateAllowedEvaluation(
        PromptEvaluation evaluation,
        bool expectPromptShieldEnabled,
        bool expectPurviewEnabled)
    {
        if (!evaluation.Allowed
            || evaluation.EvaluationReceiptId is null
            || evaluation.EvaluationReceiptId == Guid.Empty
            || !string.Equals(evaluation.Decision, "PROMPT_ALLOWED", StringComparison.Ordinal)
            || !string.Equals(
                evaluation.PromptShieldProcessing,
                expectPromptShieldEnabled ? "Allowed" : "Disabled",
                StringComparison.Ordinal)
            || !IsExpectedPurviewDecision(evaluation.PurviewProcessing, expectPurviewEnabled))
        {
            throw new InvalidOperationException(
                "The safe prompt did not return the exact reviewed protection decision.");
        }

        return evaluation with
        {
            CorrelationId = RequireCorrelation(
                evaluation.CorrelationId,
                evaluation.HeaderCorrelationId,
                requireBodyValue: true)
        };
    }

    internal static PromptEvaluation ValidateBlockedEvaluation(
        PromptEvaluation evaluation,
        bool expectPurviewEnabled)
    {
        if (evaluation.Allowed
            || evaluation.EvaluationReceiptId is not null
            || !string.Equals(
                evaluation.Decision,
                "PROMPT_BLOCKED_BY_PROMPT_SHIELD",
                StringComparison.Ordinal)
            || !string.Equals(evaluation.PromptShieldProcessing, "Blocked", StringComparison.Ordinal)
            || !IsExpectedPurviewDecision(evaluation.PurviewProcessing, expectPurviewEnabled))
        {
            throw new InvalidOperationException(
                "The injection prompt did not return the exact reviewed Prompt Shields block.");
        }

        return evaluation with
        {
            CorrelationId = RequireCorrelation(
                evaluation.CorrelationId,
                evaluation.HeaderCorrelationId,
                requireBodyValue: true)
        };
    }

    internal static string RequireHeaderCorrelation(string? value) =>
        RequireCorrelation(null, value, requireBodyValue: false);

    private static bool IsExpectedPurviewDecision(string value, bool expectPurviewEnabled) =>
        expectPurviewEnabled
            ? NonBlockingPurviewDecisions.Contains(value)
            : string.Equals(value, "PurviewDisabled", StringComparison.Ordinal);

    private static string RequireCorrelation(
        string? bodyValue,
        string? headerValue,
        bool requireBodyValue)
    {
        var parsedBody = ParseOptionalCorrelation(bodyValue);
        var parsedHeader = ParseOptionalCorrelation(headerValue);
        if ((requireBodyValue && parsedBody is null) || parsedHeader is null)
        {
            throw new InvalidOperationException(
                "Gateway response correlation evidence was missing, malformed, or inconsistent.");
        }

        return (parsedBody ?? parsedHeader)!.Value.ToString("D");
    }

    private static Guid? ParseOptionalCorrelation(string? value)
    {
        if (value is null)
            return null;
        return value.Length == 36 && Guid.TryParseExact(value, "D", out var parsed) && parsed != Guid.Empty
            ? parsed
            : throw new InvalidOperationException(
                "Gateway response correlation evidence was missing, malformed, or inconsistent.");
    }
}
