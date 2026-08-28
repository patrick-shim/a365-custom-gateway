using FluentValidation;
using Gateway.Application.Agents.Commands;
using Gateway.Domain.Enums;

namespace Gateway.Application.Agents.Validators;

public class UpdateFeaturesValidator : AbstractValidator<UpdateFeaturesCommand>
{
    public UpdateFeaturesValidator()
    {
        RuleFor(x => x.ObservabilityMode)
            .Must(BeValidObservabilityMode)
            .WithMessage("ObservabilityMode must be a valid value.")
            .When(x => x.ObservabilityMode is not null);

        RuleFor(x => x.PurviewMode)
            .Must(BeValidPurviewMode)
            .WithMessage("PurviewMode must be a valid value.")
            .When(x => x.PurviewMode is not null);

        RuleFor(x => x)
            .Must(HaveCompatibleObservabilitySettings)
            .WithMessage("Legacy and destination-specific observability settings must describe the same destinations.")
            .OverridePropertyName(nameof(UpdateFeaturesCommand.ObservabilityMode));
    }

    private static bool BeValidObservabilityMode(string? mode) =>
        Enum.TryParse<ObservabilityMode>(mode, out var parsed) && Enum.IsDefined(parsed);

    private static bool BeValidPurviewMode(string? mode) =>
        Enum.TryParse<PurviewMode>(mode, out var parsed) && Enum.IsDefined(parsed);

    private static bool HaveCompatibleObservabilitySettings(UpdateFeaturesCommand command)
    {
        if (command.ObservabilityMode is not null &&
            !BeValidObservabilityMode(command.ObservabilityMode))
        {
            return true;
        }

        return ObservabilityModeExtensions.TryResolve(
            command.ObservabilityMode,
            command.Agent365ObservabilityEnabled,
            command.AzureMonitorExportEnabled,
            ObservabilityMode.Agent365,
            out _);
    }
}
