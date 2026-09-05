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

        RuleFor(x => x.Features!.ObservabilityMode)
            .Must(BeValidObservabilityMode)
            .WithMessage("ObservabilityMode must be a valid value.")
            .When(x => x.Features?.ObservabilityMode is not null);

        RuleFor(x => x.Features)
            .Must(HaveCompatibleObservabilitySettings)
            .WithMessage("Legacy and destination-specific observability settings must describe the same destinations.")
            .When(x => x.Features is not null);

        RuleFor(x => x.Features!.PurviewMode)
            .Must(BeValidPurviewMode)
            .WithMessage("PurviewMode must be AuditOnly or Enforce.")
            .When(x => x.Features?.PurviewMode is not null);

        RuleFor(x => x.Blueprint)
            .NotNull()
            .WithMessage("Blueprint selection is required.");

        When(x => x.Blueprint is not null, () =>
        {
            RuleFor(x => x.Blueprint!.Mode)
                .Must(mode => mode is "UseExisting" or "CreateNew")
                .WithMessage("Blueprint mode must be UseExisting or CreateNew.");

            When(x => x.Blueprint!.Mode == "UseExisting", () =>
            {
                RuleFor(x => x.Blueprint!.BlueprintObjectId)
                    .NotEmpty()
                    .Must(BeNonEmptyGuid)
                    .WithMessage("BlueprintObjectId must identify an existing Agent Identity blueprint.");
                RuleFor(x => x.Blueprint!.DisplayName)
                    .Must(string.IsNullOrWhiteSpace)
                    .WithMessage("DisplayName is only valid when creating a new blueprint.");
            });

            When(x => x.Blueprint!.Mode == "CreateNew", () =>
            {
                RuleFor(x => x.Blueprint!.BlueprintObjectId)
                    .Must(string.IsNullOrWhiteSpace)
                    .WithMessage("BlueprintObjectId is only valid when selecting an existing blueprint.");
                RuleFor(x => x.Blueprint!.DisplayName)
                    .NotEmpty()
                    .MaximumLength(256);
            });
        });

        RuleFor(x => x.PurviewPolicyProfile)
            .Must(selection => selection is null)
            .WithMessage("PurviewPolicyProfile is only valid when Purview is enabled for a new blueprint.")
            .When(x => x.Blueprint?.Mode != "CreateNew" || x.Features?.PurviewEnabled != true);

        RuleFor(x => x.PurviewDlpProfile!.ProfileId)
            .NotEmpty()
            .When(x => x.PurviewDlpProfile is not null);
        RuleFor(x => x.PurviewDlpProfile!.BlueprintApplicationId)
            .NotEmpty()
            .When(x => x.PurviewDlpProfile is not null);
        RuleFor(x => x.PurviewDlpProfile!.ExpectedProfileRowVersion)
            .Must(BeExpectedRowVersion)
            .When(x =>
                x.PurviewDlpProfile?.ExpectedProfileRowVersion is not null);
        RuleFor(x => x.Features!.PurviewDlpProfile!.ProfileId)
            .NotEmpty()
            .When(x => x.Features?.PurviewDlpProfile is not null);
        RuleFor(x => x.Features!.PurviewDlpProfile!.BlueprintApplicationId)
            .NotEmpty()
            .When(x => x.Features?.PurviewDlpProfile is not null);
        RuleFor(x => x.Features!.PurviewDlpProfile!.ExpectedProfileRowVersion)
            .Must(BeExpectedRowVersion)
            .When(x =>
                x.Features?.PurviewDlpProfile?.ExpectedProfileRowVersion is not null);
        RuleFor(x => x)
            .Must(HaveMatchingDlpSelections)
            .WithMessage("Top-level and feature DLP profile selections must match.");
        RuleFor(x => x.PurviewDlpProfile)
            .Null()
            .When(x => x.Features?.PurviewEnabled == false)
            .WithMessage("PurviewDlpProfile cannot be selected while Purview is disabled.");

        When(
            x => x.Blueprint?.Mode == "CreateNew" && x.Features?.PurviewEnabled == true,
            () =>
            {
                RuleFor(x => x.PurviewPolicyProfile)
                    .NotNull()
                    .WithMessage("Select an existing Purview profile or create a new one.");

                When(x => x.PurviewPolicyProfile is not null, () =>
                {
                    RuleFor(x => x.PurviewPolicyProfile!.Mode)
                        .Must(mode => mode is "UseExisting" or "CreateNew")
                        .WithMessage("Purview profile mode must be UseExisting or CreateNew.");

                    When(x => x.PurviewPolicyProfile!.Mode == "UseExisting", () =>
                    {
                        RuleFor(x => x.PurviewPolicyProfile!.ProfileId)
                            .NotNull()
                            .Must(id => id is { } value && value != Guid.Empty)
                            .WithMessage("Select an existing Purview profile.");
                        RuleFor(x => x.PurviewPolicyProfile!.DisplayName)
                            .Must(string.IsNullOrWhiteSpace)
                            .WithMessage("DisplayName is only valid when creating a Purview profile.");
                    });

                    When(x => x.PurviewPolicyProfile!.Mode == "CreateNew", () =>
                    {
                        RuleFor(x => x.PurviewPolicyProfile!.ProfileId)
                            .Null()
                            .WithMessage("ProfileId is only valid when selecting an existing Purview profile.");
                        RuleFor(x => x.PurviewPolicyProfile!.DisplayName)
                            .NotEmpty()
                            .MaximumLength(120);
                        RuleFor(x => x.PurviewPolicyProfile!.Template)
                            .Equal("AllSensitiveInformation")
                            .WithMessage("Only the reviewed AllSensitiveInformation template is currently supported.");
                    });
                });
            });
    }

    private static bool BeValidAgentEnvironment(string env) =>
        Enum.TryParse<AgentEnvironment>(env, out _);

    private static bool BeValidObservabilityMode(string? mode) =>
        Enum.TryParse<ObservabilityMode>(mode, out var parsed) && Enum.IsDefined(parsed);

    private static bool BeValidPurviewMode(string? mode) =>
        Enum.TryParse<PurviewMode>(mode, out var parsed) && Enum.IsDefined(parsed);

    private static bool BeNonEmptyGuid(string? value) =>
        Guid.TryParse(value, out var parsed) && parsed != Guid.Empty;

    private static bool HaveCompatibleObservabilitySettings(Gateway.Contracts.Dtos.AgentFeaturesDto? features)
    {
        if (features is null ||
            (features.ObservabilityMode is not null && !BeValidObservabilityMode(features.ObservabilityMode)))
        {
            return true;
        }

        return ObservabilityModeExtensions.TryResolve(
            features.ObservabilityMode,
            features.Agent365ObservabilityEnabled,
            features.AzureMonitorExportEnabled,
            ObservabilityMode.Agent365,
            out _);
    }

    private static bool HaveMatchingDlpSelections(RegisterAgentCommand command) =>
        command.PurviewDlpProfile is null ||
        command.Features?.PurviewDlpProfile is null ||
        command.PurviewDlpProfile ==
        command.Features.PurviewDlpProfile;

    private static bool BeExpectedRowVersion(string? value)
    {
        if (value is null)
            return true;
        try
        {
            var decoded = Convert.FromBase64String(value);
            return decoded.Length == 8 &&
                string.Equals(
                    Convert.ToBase64String(decoded),
                    value,
                    StringComparison.Ordinal);
        }
        catch (FormatException)
        {
            return false;
        }
    }
}
