using Gateway.Domain.Models;

namespace Gateway.Domain.Interfaces;

public interface IObservabilityExporter
{
    Task ExportActivityAsync(ObservabilityExportRequest request, CancellationToken ct);
}
