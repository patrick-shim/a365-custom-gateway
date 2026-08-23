namespace Gateway.Application.Exceptions;

public sealed class NotFoundException : Exception
{
    public string Entity { get; }
    public string Key { get; }

    public NotFoundException(string entity, object key)
        : base($"{entity} with key '{key}' was not found.")
    {
        Entity = entity;
        Key = key.ToString() ?? string.Empty;
    }
}
