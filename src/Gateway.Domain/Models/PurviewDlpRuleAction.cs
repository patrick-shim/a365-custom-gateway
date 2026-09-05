using Gateway.Domain.Enums;

namespace Gateway.Domain.Models;

public sealed record PurviewDlpRuleAction(
    PurviewPolicyActivity Activity,
    PurviewDlpAction Action);
