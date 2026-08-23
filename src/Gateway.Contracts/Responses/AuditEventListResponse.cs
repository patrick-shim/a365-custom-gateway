namespace Gateway.Contracts.Responses;

public record AuditEventListResponse(
    List<AuditEventDto> Items,
    string? NextCursor);
