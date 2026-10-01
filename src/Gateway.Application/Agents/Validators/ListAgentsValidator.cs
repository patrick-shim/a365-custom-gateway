using FluentValidation;
using Gateway.Application.Agents.Queries;
using Gateway.Domain.Enums;

namespace Gateway.Application.Agents.Validators;

public sealed class ListAgentsValidator : AbstractValidator<ListAgentsQuery>
{
    public ListAgentsValidator()
    {
        RuleFor(query => query.Limit).InclusiveBetween(1, 200);
        RuleFor(query => query.Status)
            .Must(value => IsOptionalEnumName<AgentStatus>(value))
            .WithMessage("Status must be a valid registration status.");
        RuleFor(query => query.Environment)
            .Must(value => IsOptionalEnumName<AgentEnvironment>(value))
            .WithMessage("Environment must be Development, Test, or Production.");
        RuleFor(query => query.Search).MaximumLength(256);
        RuleFor(query => query.Cursor)
            .Must(cursor => string.IsNullOrEmpty(cursor) || ListAgentsCursor.TryDecode(cursor, out _, out _))
            .WithMessage(ListAgentsCursor.InvalidMessage);
    }

    private static bool IsOptionalEnumName<TEnum>(string? value) where TEnum : struct, Enum =>
        string.IsNullOrWhiteSpace(value) ||
        Enum.GetNames<TEnum>().Contains(value.Trim(), StringComparer.OrdinalIgnoreCase);
}
