using FluentValidation;
using Gateway.Application.Agents.Commands;
using Gateway.Domain.Enums;

namespace Gateway.Application.Agents.Validators;

public class RegisterAgentValidator : AbstractValidator<RegisterAgentCommand>
{
    public RegisterAgentValidator()
    {
        RuleFor(x => x.ExternalAgentId)
            .NotEmpty()
            .MaximumLength(128)
            .Matches(@"^[a-zA-Z0-9][a-zA-Z0-9._-]*$");

        RuleFor(x => x.Name)
            .NotEmpty()
            .MaximumLength(256);

        RuleFor(x => x.Description)
            .MaximumLength(2000)
            .When(x => x.Description is not null);

        RuleFor(x => x.OwnerObjectId)
            .NotEmpty()
            .MaximumLength(64);

        RuleFor(x => x.Environment)
            .NotEmpty()
            .Must(BeValidAgentEnvironment)
            .WithMessage("Environment must be a valid AgentEnvironment value.");
    }

    private static bool BeValidAgentEnvironment(string env) =>
        Enum.TryParse<AgentEnvironment>(env, out _);
}
