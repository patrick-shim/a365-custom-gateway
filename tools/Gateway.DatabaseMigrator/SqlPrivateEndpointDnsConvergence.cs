using System.Net;
using System.Net.Sockets;

namespace Gateway.DatabaseMigrator;

public static class SqlPrivateEndpointDnsConvergence
{
    public const int DefaultMaximumAttempts = 121;
    public static readonly TimeSpan DefaultRetryDelay = TimeSpan.FromSeconds(5);

    private const string ConvergenceFailureMessage =
        "Private SQL DNS did not converge to the exact reviewed private endpoint within the bounded wait.";

    public static IPAddress ParseCanonicalPrivateIpv4(string? value)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            !IPAddress.TryParse(value, out var address) ||
            address.AddressFamily != AddressFamily.InterNetwork ||
            !string.Equals(value, address.ToString(), StringComparison.Ordinal) ||
            !IsPrivateIpv4(address))
        {
            throw new ArgumentException(
                "--expected-private-endpoint-ip must be one canonical private IPv4 address for the reviewed SQL private endpoint.");
        }

        return address;
    }

    public static Task WaitForExactResolutionAsync(
        string serverFqdn,
        IPAddress expectedPrivateEndpointIp,
        CancellationToken cancellationToken = default) =>
        WaitForExactResolutionAsync(
            serverFqdn,
            expectedPrivateEndpointIp,
            static (host, token) => Dns.GetHostAddressesAsync(host, token),
            static (delay, token) => Task.Delay(delay, token),
            DefaultMaximumAttempts,
            DefaultRetryDelay,
            cancellationToken);

    public static async Task WaitForExactResolutionAsync(
        string serverFqdn,
        IPAddress expectedPrivateEndpointIp,
        Func<string, CancellationToken, Task<IPAddress[]>> resolveAsync,
        Func<TimeSpan, CancellationToken, Task> delayAsync,
        int maximumAttempts,
        TimeSpan retryDelay,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(serverFqdn);
        ArgumentNullException.ThrowIfNull(expectedPrivateEndpointIp);
        ArgumentNullException.ThrowIfNull(resolveAsync);
        ArgumentNullException.ThrowIfNull(delayAsync);
        if (expectedPrivateEndpointIp.AddressFamily != AddressFamily.InterNetwork ||
            !IsPrivateIpv4(expectedPrivateEndpointIp))
        {
            throw new ArgumentException(
                "The expected SQL private-endpoint address must be a private IPv4 address.",
                nameof(expectedPrivateEndpointIp));
        }
        if (maximumAttempts < 1)
            throw new ArgumentOutOfRangeException(nameof(maximumAttempts));
        if (retryDelay <= TimeSpan.Zero)
            throw new ArgumentOutOfRangeException(nameof(retryDelay));

        for (var attempt = 1; attempt <= maximumAttempts; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();

            IPAddress[] addresses;
            try
            {
                addresses = await resolveAsync(serverFqdn, cancellationToken) ?? [];
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (SocketException)
            {
                addresses = [];
            }

            var distinctAddresses = addresses.Distinct().ToArray();
            if (distinctAddresses.Length == 1 &&
                distinctAddresses[0].AddressFamily == AddressFamily.InterNetwork &&
                distinctAddresses[0].Equals(expectedPrivateEndpointIp))
            {
                return;
            }

            if (attempt < maximumAttempts)
                await delayAsync(retryDelay, cancellationToken);
        }

        throw new InvalidOperationException(ConvergenceFailureMessage);
    }

    private static bool IsPrivateIpv4(IPAddress address)
    {
        var bytes = address.GetAddressBytes();
        return bytes.Length == 4 &&
               (bytes[0] == 10 ||
                (bytes[0] == 172 && bytes[1] is >= 16 and <= 31) ||
                (bytes[0] == 192 && bytes[1] == 168));
    }
}
