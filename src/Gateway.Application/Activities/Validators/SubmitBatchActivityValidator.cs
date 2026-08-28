using FluentValidation;
using Gateway.Application.Activities.Commands;
using Gateway.Contracts.Dtos;
using Gateway.Domain.Enums;

namespace Gateway.Application.Activities.Validators;

public sealed class SubmitBatchActivityValidator : AbstractValidator<SubmitBatchActivityCommand>
{
    public SubmitBatchActivityValidator()
    {
        RuleFor(command => command.ExternalAgentId)
            .NotEmpty()
            .Length(3, 128)
            .Matches(@"^[a-zA-Z0-9][a-zA-Z0-9._-]*$");

        RuleFor(command => command.Activities)
            .NotNull()
            .Must(activities => activities is { Count: >= 1 and <= 100 })
            .WithMessage("Activities must contain between 1 and 100 items.");

        RuleForEach(command => command.Activities)
            .NotNull()
            .SetValidator(new BatchActivityItemValidator());
    }

    private sealed class BatchActivityItemValidator : AbstractValidator<BatchActivityItemDto>
    {
        public BatchActivityItemValidator()
        {
            RuleFor(item => item.ActivityId)
                .NotEmpty()
                .MaximumLength(256);

            RuleFor(item => item.SessionId)
                .MaximumLength(256)
                .When(item => item.SessionId is not null);

            RuleFor(item => item.ActivityType)
                .NotEmpty()
                .Must(BeDefined<ActivityType>)
                .WithMessage("ActivityType must be a valid value.");

            RuleFor(item => item.OccurredAtUtc)
                .NotEqual(default(DateTime))
                .LessThanOrEqualTo(_ => DateTime.UtcNow)
                .WithMessage("OccurredAtUtc must not be in the future.");

            RuleFor(item => item.Actor)
                .NotNull();

            When(item => item.Actor is not null, () =>
            {
                RuleFor(item => item.Actor.Type)
                    .NotEmpty()
                    .Must(BeDefined<ActorType>)
                    .WithMessage("Actor.Type must be a valid value.");
            });

            When(item => item.Tool is not null, () =>
            {
                RuleFor(item => item.Tool!.Name)
                    .NotEmpty();
                RuleFor(item => item.Tool!.Outcome)
                    .NotEmpty()
                    .Must(BeDefined<ToolOutcome>)
                    .WithMessage("Tool.Outcome must be a valid value.");
                RuleFor(item => item.Tool!.DurationMs)
                    .GreaterThanOrEqualTo(0)
                    .When(item => item.Tool!.DurationMs is not null);
            });

            RuleFor(item => item.Attributes)
                .Must(attributes => attributes is null ||
                    (attributes.Count <= 20 &&
                     attributes.All(pair =>
                         pair.Value is not null && pair.Value.Length <= 256)))
                .WithMessage("Attributes must contain at most 20 values of at most 256 characters each.");
        }

        private static bool BeDefined<TEnum>(string value)
            where TEnum : struct, Enum =>
            Enum.TryParse<TEnum>(value, out var parsed) && Enum.IsDefined(parsed);
    }
}
