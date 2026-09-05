using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using MediatR;

namespace Gateway.Application.Agents.Commands;

public record UpdateFeaturesCommand(
    Guid AgentId,
    string? ObservabilityMode,
    bool? PurviewEnabled,
    string? PurviewMode,
    string CallerObjectId,
    bool? Agent365ObservabilityEnabled = null,
    bool? AzureMonitorExportEnabled = null,
    bool? PromptShieldEnabled = null,
    PurviewDlpProfileSelectionDto? PurviewDlpProfile = null,
    Guid? IdempotencyKey = null,
    string? ExpectedRowVersion = null)
    : IRequest<UpdateFeaturesResponse>;
