namespace Gateway.AdminUi.Models;

public static class PurviewCompanionInputLimits
{
    public const int MaximumOutputBytes = 512 * 1024;
    public const int MaximumPayloadBytes = 384 * 1024;

    // A pasted base64 result plus its event envelope exceeds SignalR's default 32 KB.
    public const int MaximumHubMessageBytes = 1024 * 1024;
}
