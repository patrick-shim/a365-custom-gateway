namespace Gateway.Application.Exceptions;

public sealed class InvalidStateTransitionException : Exception
{
    public string CurrentState { get; }
    public string AttemptedAction { get; }

    public InvalidStateTransitionException(string currentState, string attemptedAction)
        : base($"Cannot perform '{attemptedAction}' when agent is in '{currentState}' state.")
    {
        CurrentState = currentState;
        AttemptedAction = attemptedAction;
    }
}
