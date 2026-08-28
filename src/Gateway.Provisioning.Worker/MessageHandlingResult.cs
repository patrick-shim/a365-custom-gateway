namespace Gateway.Provisioning.Worker;

internal sealed record MessageHandlingResult(
    bool ShouldDeadLetter,
    string? DeadLetterReason,
    string? DeadLetterDescription)
{
    public static MessageHandlingResult Complete() => new(false, null, null);

    public static MessageHandlingResult DeadLetter(string reason, string description) =>
        new(true, reason, description);
}
