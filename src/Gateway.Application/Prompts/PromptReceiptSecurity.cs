using System.Security.Cryptography;
using System.Text;

namespace Gateway.Application.Prompts;

internal static class PromptReceiptSecurity
{
    public static (byte[] Salt, byte[] Hash) Create(string contentType, string content)
    {
        var salt = RandomNumberGenerator.GetBytes(32);
        return (salt, Compute(salt, contentType, content));
    }

    public static bool Verify(byte[] salt, byte[] expectedHash, string contentType, string content)
    {
        var actualHash = Compute(salt, contentType, content);
        try
        {
            return CryptographicOperations.FixedTimeEquals(actualHash, expectedHash);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(actualHash);
        }
    }

    private static byte[] Compute(byte[] salt, string contentType, string content)
    {
        var value = Encoding.UTF8.GetBytes($"{contentType}\n{content}");
        try
        {
            var payload = new byte[salt.Length + value.Length];
            salt.CopyTo(payload, 0);
            value.CopyTo(payload, salt.Length);
            try
            {
                return SHA256.HashData(payload);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(payload);
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(value);
        }
    }
}
