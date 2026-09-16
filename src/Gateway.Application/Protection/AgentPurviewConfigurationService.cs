using Gateway.Application.Exceptions;
using Gateway.Contracts;
using Gateway.Contracts.Dtos;
using Gateway.Contracts.Requests;
using Gateway.Domain.Entities;
using MediatR;

namespace Gateway.Application.Protection;

internal sealed class AgentPurviewConfigurationService(ISender sender)
{
    public async Task ApplyAsync(AgentRegistration agent, PurviewConfigurationIntentDto intent,
        Guid? tenantId, string actorObjectId, Guid? resolvedBlueprintApplicationId, CancellationToken ct)
    {
        if (tenantId is null || tenantId == Guid.Empty)
            throw new ProtectionAccessDeniedException();
        if (intent.ConfirmationTokenId == Guid.Empty || intent.IdempotencyKey == Guid.Empty ||
            string.IsNullOrWhiteSpace(intent.ConfirmationToken))
            throw new DomainException("Reviewed configuration consent is required.", ErrorCodes.PROTECTION_CONFIRMATION_INVALID);
        await sender.Send(new StartPurviewDlpProfileCommand(
            new ProtectionActor(tenantId.Value, actorObjectId),
            new StartPurviewDlpProfileOperationRequest(intent.ConfirmationTokenId, intent.ConfirmationToken,
                intent.IdempotencyKey, intent.ExpectedRowVersion),
            agent, resolvedBlueprintApplicationId), ct);
    }
}
