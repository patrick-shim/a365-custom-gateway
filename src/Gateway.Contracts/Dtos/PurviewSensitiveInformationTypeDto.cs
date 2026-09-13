namespace Gateway.Contracts.Dtos;

public sealed record PurviewSensitiveInformationTypeDto(
    Guid Id,
    string ExactName,
    string Publisher);

/// <summary>
/// DLP matches any selected SIT (OR). Counts are positive Int32 values; MaxCount -1 means Any.
/// Confidence bounds are inclusive 1–100. Omitted values become explicit example defaults
/// only during a new-policy review; existing-policy omissions require proven thresholds.
/// </summary>
public sealed record PurviewSensitiveInformationTypeSelectionDto(
    Guid InventoryGenerationId,
    Guid SensitiveInformationTypeId,
    string ExactName,
    int? MinCount = null,
    int? MaxCount = null,
    int? MinConfidence = null,
    int? MaxConfidence = null);
