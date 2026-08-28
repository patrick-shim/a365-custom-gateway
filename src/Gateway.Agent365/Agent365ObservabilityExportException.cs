namespace Gateway.Agent365;

public abstract class Agent365ObservabilityExportException : Exception
{
    protected Agent365ObservabilityExportException(string code, Exception? innerException = null)
        : base($"Agent 365 observability export failed ({code}).", innerException)
    {
        Code = code;
    }

    public string Code { get; }
}

public sealed class Agent365ObservabilityConfigurationException : Agent365ObservabilityExportException
{
    public Agent365ObservabilityConfigurationException(string code, Exception? innerException = null)
        : base(code, innerException)
    {
    }
}

public sealed class Agent365ObservabilityTransientException : Agent365ObservabilityExportException
{
    public Agent365ObservabilityTransientException(string code, Exception? innerException = null)
        : base(code, innerException)
    {
    }
}
