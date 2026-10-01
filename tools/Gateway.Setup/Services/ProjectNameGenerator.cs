using System.Security.Cryptography;

namespace Gateway.Setup.Services;

internal interface IProjectNameGenerator
{
    string Create();
}

internal sealed class ProjectNameGenerator : IProjectNameGenerator
{
    public string Create()
    {
        var random = RandomNumberGenerator.GetBytes(3);
        try
        {
            return FromBytes(random);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(random);
        }
    }

    internal static string FromBytes(ReadOnlySpan<byte> random)
    {
        if (random.Length < 3)
        {
            throw new ArgumentException("At least three random bytes are required.", nameof(random));
        }

        return $"gw{Convert.ToHexStringLower(random[..3])[..5]}";
    }
}
