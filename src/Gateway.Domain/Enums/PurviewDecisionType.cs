namespace Gateway.Domain.Enums;

public enum PurviewDecisionType
{
    Allowed,
    Blocked,
    AuditOnly,
    AuditLogged,
    PurviewSkipped_NoUserContext,
    PurviewSkipped_InvalidUser,
    PurviewDisabled
}
