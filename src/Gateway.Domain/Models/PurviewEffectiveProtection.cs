using Gateway.Domain.Entities;
using Gateway.Domain.Enums;
using Gateway.Domain.ValueObjects;

namespace Gateway.Domain.Models;

public sealed record PurviewEffectiveProtection(
    bool IsRequested,
    bool IsEnabled,
    PurviewEffectiveEnablementStatus Status,
    PurviewDlpProfileId? ProfileId)
{
    public static PurviewEffectiveProtection Evaluate(
        bool requested,
        BlueprintApplicationId? registrationBlueprintApplicationId,
        PurviewDlpProfileId? selectedProfileId,
        PurviewDlpProfile? profile,
        DateTime utcNow)
    {
        if (!requested)
            return new(false, false, PurviewEffectiveEnablementStatus.Disabled, selectedProfileId);
        if (registrationBlueprintApplicationId is null)
            return new(true, false, PurviewEffectiveEnablementStatus.BlueprintRequired, selectedProfileId);
        if (selectedProfileId is null || profile is null)
            return new(true, false, PurviewEffectiveEnablementStatus.ProfileRequired, selectedProfileId);
        if (profile.Id != selectedProfileId ||
            profile.BlueprintApplicationId != registrationBlueprintApplicationId)
            return new(true, false, PurviewEffectiveEnablementStatus.ProfileMismatch, selectedProfileId);
        if (!profile.IsExactlyReadyFor(registrationBlueprintApplicationId.Value, utcNow))
            return new(true, false, PurviewEffectiveEnablementStatus.ProfileNotReady, selectedProfileId);

        return new(true, true, PurviewEffectiveEnablementStatus.Ready, selectedProfileId);
    }
}
