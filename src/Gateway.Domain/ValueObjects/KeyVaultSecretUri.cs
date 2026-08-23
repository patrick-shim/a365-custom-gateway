namespace Gateway.Domain.ValueObjects;

public readonly record struct KeyVaultSecretUri
{
    public string Value { get; }

    public KeyVaultSecretUri(string value)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(value);

        if (!value.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("KeyVaultSecretUri must use HTTPS.", nameof(value));

        if (!value.Contains(".vault.azure.net", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException(
                "KeyVaultSecretUri must reference an Azure Key Vault (.vault.azure.net).",
                nameof(value));

        Value = value;
    }

    public override string ToString() => Value;
}
