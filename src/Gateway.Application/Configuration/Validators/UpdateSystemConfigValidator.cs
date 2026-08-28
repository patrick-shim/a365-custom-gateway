using FluentValidation;
using Gateway.Application.Configuration.Commands;
using Gateway.Domain.Enums;

namespace Gateway.Application.Configuration.Validators;

public sealed class UpdateSystemConfigValidator : AbstractValidator<UpdateSystemConfigCommand>
{
    public UpdateSystemConfigValidator()
    {
        RuleFor(x => x.DefaultObservabilityMode)
            .Must(BeValidObservabilityMode)
            .WithMessage("DefaultObservabilityMode must be a valid value.")
            .When(x => x.DefaultObservabilityMode is not null);

        RuleFor(x => x.DefaultPurviewMode)
            .Must(BeValidPurviewMode)
            .WithMessage("DefaultPurviewMode must be AuditOnly or Enforce.")
            .When(x => x.DefaultPurviewMode is not null);

        RuleFor(x => x)
            .Must(HaveCompatibleObservabilitySettings)
            .WithMessage("Legacy and destination-specific observability settings must describe the same destinations.")
            .OverridePropertyName(nameof(UpdateSystemConfigCommand.DefaultObservabilityMode));
    }

    private static bool BeValidObservabilityMode(string? mode) =>
        Enum.TryParse<ObservabilityMode>(mode, out var parsed) && Enum.IsDefined(parsed);

    private static bool BeValidPurviewMode(string? mode) =>
        Enum.TryParse<PurviewMode>(mode, out var parsed) && Enum.IsDefined(parsed);

    private static bool HaveCompatibleObservabilitySettings(UpdateSystemConfigCommand command)
    {
        if (command.DefaultObservabilityMode is not null &&
            !BeValidObservabilityMode(command.DefaultObservabilityMode))
        {
            return true;
        }

        return ObservabilityModeExtensions.TryResolve(
            command.DefaultObservabilityMode,
            command.DefaultAgent365ObservabilityEnabled,
            command.DefaultAzureMonitorExportEnabled,
            ObservabilityMode.Agent365,
            out _);
    }
}
