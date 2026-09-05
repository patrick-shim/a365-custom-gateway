using System.ComponentModel.DataAnnotations;

namespace Gateway.Setup.Models;

internal enum CapabilityPreset
{
    FullEvaluation,
    CoreGateway,
    Custom
}

internal static class CapabilityPresetExtensions
{
    public static string DisplayName(this CapabilityPreset preset) => preset switch
    {
        CapabilityPreset.FullEvaluation => "Full evaluation",
        CapabilityPreset.CoreGateway => "Core Gateway",
        CapabilityPreset.Custom => "Custom",
        _ => throw new ArgumentOutOfRangeException(nameof(preset), preset, null)
    };

    public static string ConfigurationValue(this CapabilityPreset preset) => preset switch
    {
        CapabilityPreset.FullEvaluation => "fullEvaluation",
        CapabilityPreset.CoreGateway => "coreGateway",
        CapabilityPreset.Custom => "custom",
        _ => throw new ArgumentOutOfRangeException(nameof(preset), preset, null)
    };

    public static CapabilityPreset ParseConfigurationValue(string? value) => value switch
    {
        "fullEvaluation" => CapabilityPreset.FullEvaluation,
        "coreGateway" => CapabilityPreset.CoreGateway,
        "custom" => CapabilityPreset.Custom,
        _ => throw new ValidationException("The capability preset is not supported.")
    };
}
