namespace Gateway.Contracts.Requests;

public sealed record DeleteRegisteredAgentRequest(string ExpectedRowVersion, bool ConfirmPermanentDeletion);
