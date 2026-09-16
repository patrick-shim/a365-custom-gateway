namespace Gateway.Contracts.Dtos;

/// <summary>A single-use, reviewed and confirmed DLP configuration authorization.</summary>
public sealed record PurviewConfigurationIntentDto(
    Guid ConfirmationTokenId,
    string ConfirmationToken,
    Guid IdempotencyKey,
    string ExpectedRowVersion);

/// <summary>Consent bound to exactly one new registration and its new blueprint.</summary>
public sealed record PurviewDeferredBlueprintDto(
    string ExternalAgentId,
    string DisplayName);
