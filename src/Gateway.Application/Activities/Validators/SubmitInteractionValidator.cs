using FluentValidation;
using Gateway.Application.Interactions.Commands;

namespace Gateway.Application.Activities.Validators;

public class SubmitInteractionValidator : AbstractValidator<SubmitInteractionCommand>
{
    public SubmitInteractionValidator()
    {
        RuleFor(x => x.ExternalAgentId)
            .NotEmpty();

        RuleFor(x => x.InteractionId)
            .NotEmpty()
            .MaximumLength(256);

        RuleFor(x => x.OccurredAtUtc)
            .Must(NotBeInFuture)
            .WithMessage("OccurredAtUtc must not be in the future.");

        RuleFor(x => x.Prompt)
            .NotNull();

        RuleFor(x => x.Prompt.Content)
            .NotEmpty()
            .When(x => x.Prompt is not null);

        RuleFor(x => x.Prompt.ContentType)
            .NotEmpty()
            .When(x => x.Prompt is not null);

        RuleFor(x => x.Response)
            .NotNull();

        RuleFor(x => x.Response.Content)
            .NotEmpty()
            .When(x => x.Response is not null);

        RuleFor(x => x.Response.ContentType)
            .NotEmpty()
            .When(x => x.Response is not null);
    }

    private static bool NotBeInFuture(DateTime dt) =>
        dt <= DateTime.UtcNow;
}
