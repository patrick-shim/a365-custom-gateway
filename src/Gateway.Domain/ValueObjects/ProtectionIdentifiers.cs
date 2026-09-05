namespace Gateway.Domain.ValueObjects;

public readonly record struct EntraTenantId
{
    public Guid Value { get; }

    public EntraTenantId(Guid value)
    {
        ArgumentOutOfRangeException.ThrowIfEqual(value, Guid.Empty);
        Value = value;
    }

    public override string ToString() => Value.ToString("D");
}

public readonly record struct BlueprintObjectId
{
    public Guid Value { get; }

    public BlueprintObjectId(Guid value)
    {
        ArgumentOutOfRangeException.ThrowIfEqual(value, Guid.Empty);
        Value = value;
    }

    public override string ToString() => Value.ToString("D");
}

public readonly record struct BlueprintApplicationId
{
    public Guid Value { get; }

    public BlueprintApplicationId(Guid value)
    {
        ArgumentOutOfRangeException.ThrowIfEqual(value, Guid.Empty);
        Value = value;
    }

    public override string ToString() => Value.ToString("D");
}

public readonly record struct ApplicationClientId
{
    public Guid Value { get; }

    public ApplicationClientId(Guid value)
    {
        ArgumentOutOfRangeException.ThrowIfEqual(value, Guid.Empty);
        Value = value;
    }

    public override string ToString() => Value.ToString("D");
}

public readonly record struct ServicePrincipalObjectId
{
    public Guid Value { get; }

    public ServicePrincipalObjectId(Guid value)
    {
        ArgumentOutOfRangeException.ThrowIfEqual(value, Guid.Empty);
        Value = value;
    }

    public override string ToString() => Value.ToString("D");
}

public readonly record struct ChildAgentIdentityObjectId
{
    public Guid Value { get; }

    public ChildAgentIdentityObjectId(Guid value)
    {
        ArgumentOutOfRangeException.ThrowIfEqual(value, Guid.Empty);
        Value = value;
    }

    public override string ToString() => Value.ToString("D");
}

public readonly record struct SensitiveInformationTypeSnapshotGenerationId
{
    public Guid Value { get; }

    public SensitiveInformationTypeSnapshotGenerationId(Guid value)
    {
        ArgumentOutOfRangeException.ThrowIfEqual(value, Guid.Empty);
        Value = value;
    }

    public override string ToString() => Value.ToString("D");
}

public readonly record struct SensitiveInformationTypeId
{
    public Guid Value { get; }

    public SensitiveInformationTypeId(Guid value)
    {
        ArgumentOutOfRangeException.ThrowIfEqual(value, Guid.Empty);
        Value = value;
    }

    public override string ToString() => Value.ToString("D");
}

public readonly record struct PurviewDlpProfileId
{
    public Guid Value { get; }

    public PurviewDlpProfileId(Guid value)
    {
        ArgumentOutOfRangeException.ThrowIfEqual(value, Guid.Empty);
        Value = value;
    }

    public override string ToString() => Value.ToString("D");
}

public readonly record struct ProtectionIdempotencyKey
{
    public Guid Value { get; }

    public ProtectionIdempotencyKey(Guid value)
    {
        ArgumentOutOfRangeException.ThrowIfEqual(value, Guid.Empty);
        var canonical = value.ToString("D");
        if (canonical[14] != '4' || canonical[19] is not ('8' or '9' or 'a' or 'b'))
            throw new ArgumentException("Protection idempotency keys must be canonical UUIDv4 values.", nameof(value));

        Value = value;
    }

    public override string ToString() => Value.ToString("D");
}
