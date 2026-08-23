namespace Gateway.Domain.ValueObjects;

public readonly record struct CorrelationId
{
    public Guid Value { get; }

    public CorrelationId(Guid value)
    {
        if (value == Guid.Empty)
            throw new ArgumentException("CorrelationId cannot be empty.", nameof(value));

        Value = value;
    }

    public static CorrelationId NewCorrelationId() => new(Guid.NewGuid());

    public override string ToString() => Value.ToString();
}
