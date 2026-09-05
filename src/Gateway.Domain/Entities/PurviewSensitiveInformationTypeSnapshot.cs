using Gateway.Domain.ValueObjects;

namespace Gateway.Domain.Entities;

public class PurviewSensitiveInformationTypeSnapshot
{
    public Guid Id { get; set; }
    public SensitiveInformationTypeSnapshotGenerationId GenerationId { get; set; }
    public SensitiveInformationTypeId SensitiveInformationTypeId { get; set; }
    public string ExactName { get; set; } = string.Empty;
    public string Publisher { get; set; } = string.Empty;
    public int SortOrder { get; set; }

    public PurviewSensitiveInformationTypeSnapshotGeneration Generation { get; set; } = null!;
}
