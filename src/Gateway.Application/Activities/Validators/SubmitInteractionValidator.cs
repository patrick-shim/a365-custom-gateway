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
            .MaximumLength(32_768)
            .When(x => x.Prompt is not null);

        RuleFor(x => x.Prompt.ContentType)
            .NotEmpty()
            .Must(BeSupportedContentType)
            .WithMessage("Prompt.ContentType must be text/plain or text/markdown.")
            .When(x => x.Prompt is not null);

        RuleFor(x => x.Response)
            .NotNull();

        RuleFor(x => x.Response.Content)
            .NotEmpty()
            .MaximumLength(32_768)
            .When(x => x.Response is not null);

        RuleFor(x => x.Response.ContentType)
            .NotEmpty()
            .Must(BeSupportedContentType)
            .WithMessage("Response.ContentType must be text/plain or text/markdown.")
            .When(x => x.Response is not null);

        RuleFor(x => x.UserContext!.TenantUserObjectId)
            .Must(BeValidObjectId)
            .WithMessage("UserContext.TenantUserObjectId must be a valid GUID.")
            .When(x => x.UserContext?.TenantUserObjectId is not null);
    }

    private static bool NotBeInFuture(DateTime dt) =>
        dt <= DateTime.UtcNow;

    private static bool BeValidObjectId(string? objectId) =>
        Guid.TryParse(objectId, out var parsed) && parsed != Guid.Empty;

    private static bool BeSupportedContentType(string contentType) =>
        contentType is "text/plain" or "text/markdown";
}
