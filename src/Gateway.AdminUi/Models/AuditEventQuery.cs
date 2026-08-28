namespace Gateway.AdminUi.Models;

public sealed record AuditEventQuery(
    int Limit = 50,
    string? Cursor = null);
