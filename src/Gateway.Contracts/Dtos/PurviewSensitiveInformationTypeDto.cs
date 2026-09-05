namespace Gateway.Contracts.Dtos;

public sealed record PurviewSensitiveInformationTypeDto(
    Guid Id,
    string ExactName,
    string Publisher);

public sealed record PurviewSensitiveInformationTypeSelectionDto(
    Guid InventoryGenerationId,
    Guid SensitiveInformationTypeId,
    string ExactName);
