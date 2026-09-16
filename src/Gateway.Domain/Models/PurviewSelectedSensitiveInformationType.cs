namespace Gateway.Domain.Models;

public sealed record PurviewSelectedSensitiveInformationType(
    Guid Id,
    string ExactName,
    int? MinCount = null,
    int? MaxCount = null,
    int? MinConfidence = null,
    int? MaxConfidence = null);

public static class PurviewSensitiveInformationTypeThresholds
{
    public static bool AreValid(int? minCount, int? maxCount, int? minConfidence, int? maxConfidence) =>
        minCount is >= 1 &&
        (maxCount == -1 || maxCount >= minCount) &&
        minConfidence is >= 1 and <= 100 &&
        maxConfidence is >= 1 and <= 100 &&
        maxConfidence >= minConfidence;
}
