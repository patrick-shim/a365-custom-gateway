using FluentValidation;
using Gateway.Application.Prompts.Commands;

namespace Gateway.Application.Prompts.Validators;

public sealed class EvaluatePromptValidator : AbstractValidator<EvaluatePromptCommand>
{
    public EvaluatePromptValidator()
    {
        RuleFor(request => request.ExternalAgentId).NotEmpty();
        RuleFor(request => request.InteractionId).NotEmpty().MaximumLength(256);
        RuleFor(request => request.OccurredAtUtc)
            .LessThanOrEqualTo(_ => DateTime.UtcNow)
            .WithMessage("OccurredAtUtc must not be in the future.");
        RuleFor(request => request.Prompt).NotNull();
        RuleFor(request => request.Prompt.Content)
            .NotEmpty()
            .MaximumLength(10_000)
            .When(request => request.Prompt is not null);
        RuleFor(request => request.Prompt.ContentType)
            .Must(contentType => contentType is "text/plain" or "text/markdown")
            .WithMessage("Prompt.ContentType must be text/plain or text/markdown.")
            .When(request => request.Prompt is not null);
        RuleFor(request => request.UserContext!.TenantUserObjectId)
            .Must(value => Guid.TryParse(value, out var parsed) && parsed != Guid.Empty)
            .WithMessage("UserContext.TenantUserObjectId must be a valid GUID.")
            .When(request => request.UserContext?.TenantUserObjectId is not null);
    }
}
