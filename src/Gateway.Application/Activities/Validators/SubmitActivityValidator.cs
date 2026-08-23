using FluentValidation;
using Gateway.Application.Activities.Commands;
using Gateway.Domain.Enums;

namespace Gateway.Application.Activities.Validators;

public class SubmitActivityValidator : AbstractValidator<SubmitActivityCommand>
{
    public SubmitActivityValidator()
    {
        RuleFor(x => x.ExternalAgentId)
            .NotEmpty();

        RuleFor(x => x.ActivityId)
            .NotEmpty()
            .MaximumLength(256);

        RuleFor(x => x.ActivityType)
            .NotEmpty()
            .Must(BeValidActivityType)
            .WithMessage("ActivityType must be a valid value.");

        RuleFor(x => x.Actor)
            .NotNull();

        RuleFor(x => x.Actor.Type)
            .NotEmpty()
            .Must(BeValidActorType)
            .WithMessage("Actor.Type must be a valid value.")
            .When(x => x.Actor is not null);

        RuleFor(x => x.OccurredAtUtc)
            .Must(NotBeInFuture)
            .WithMessage("OccurredAtUtc must not be in the future.");

        When(x => x.Tool is not null, () =>
        {
            RuleFor(x => x.Tool!.Name)
                .NotEmpty();

            RuleFor(x => x.Tool!.Outcome)
                .Must(BeValidToolOutcome)
                .WithMessage("Tool.Outcome must be a valid value.");
        });
    }

    private static bool BeValidActivityType(string type) =>
        Enum.TryParse<ActivityType>(type, out _);

    private static bool BeValidActorType(string type) =>
        Enum.TryParse<ActorType>(type, out _);

    private static bool BeValidToolOutcome(string outcome) =>
        Enum.TryParse<ToolOutcome>(outcome, out _);

    private static bool NotBeInFuture(DateTime dt) =>
        dt <= DateTime.UtcNow;
}
