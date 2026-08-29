using System.Text.Json;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Responses;
using Gateway.Domain.Interfaces;
using MediatR;

namespace Gateway.Application.Agents.Queries;

internal sealed class ListPurviewPolicyProfilesHandler
    : IRequestHandler<ListPurviewPolicyProfilesQuery, PurviewPolicyProfileListResponse>
{
    private readonly IPurviewPolicyProfileRepository _repository;

    public ListPurviewPolicyProfilesHandler(IPurviewPolicyProfileRepository repository)
    {
        _repository = repository;
    }

    public async Task<PurviewPolicyProfileListResponse> Handle(
        ListPurviewPolicyProfilesQuery request,
        CancellationToken cancellationToken)
    {
        var profiles = await _repository.ListReadyAsync(cancellationToken);
        return new PurviewPolicyProfileListResponse(profiles.Select(profile =>
            new PurviewPolicyProfileSummaryDto(
                profile.Id,
                profile.DisplayName,
                profile.Template,
                profile.Mode,
                profile.Status,
                ReadBlueprintCount(profile.BlueprintApplicationIdsJson),
                profile.VerifiedAtUtc)).ToArray());
    }

    private static int ReadBlueprintCount(string json)
    {
        try
        {
            return JsonSerializer.Deserialize<string[]>(json)?.Distinct(StringComparer.Ordinal).Count() ?? 0;
        }
        catch (JsonException)
        {
            return 0;
        }
    }
}
