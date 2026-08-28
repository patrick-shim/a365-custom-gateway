using Gateway.Domain.Models;

namespace Gateway.Domain.Interfaces;

/// <summary>
/// Performs the preview Agent 365 Registry mutation with a delegated user token.
/// Implementations must never persist, queue, or log that token.
/// </summary>
public interface IAgent365DelegatedRegistryClient
{
    /// <summary>
    /// Sends the bounded, idempotent create request using the caller's durable
    /// planned Registry identifier and returns the created or existing identifier.
    /// </summary>
    Task<string> CreateAsync(
        Agent365DelegatedRegistryRequest request,
        CancellationToken cancellationToken);

    /// <summary>
    /// Reads the exact durable identifier and verifies that it maps to
    /// the expected Gateway registration and Microsoft Agent Identity resources.
    /// </summary>
    Task VerifyAsync(
        string agent365RegistrationId,
        Agent365DelegatedRegistryRequest request,
        CancellationToken cancellationToken);
}
