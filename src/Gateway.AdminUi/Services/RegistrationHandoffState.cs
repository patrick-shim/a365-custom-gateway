namespace Gateway.AdminUi.Services;

public sealed class RegistrationHandoffState
{
    private (Guid OperationId, Guid AgentId)? savedCredential;

    public void RecordSavedCredential(Guid operationId, Guid agentId)
    {
        if (operationId == Guid.Empty)
        {
            throw new ArgumentException("A registration operation is required.", nameof(operationId));
        }

        if (agentId == Guid.Empty)
        {
            throw new ArgumentException("A registered agent is required.", nameof(agentId));
        }
        savedCredential = (operationId, agentId);
    }

    public bool TryConsumeAutomaticCompletion(Guid operationId, Guid agentId)
    {
        if (savedCredential is not { } saved || saved.OperationId != operationId || saved.AgentId != agentId)
        {
            return false;
        }

        savedCredential = null;
        return true;
    }
}
