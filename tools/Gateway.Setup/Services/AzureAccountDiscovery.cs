using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Gateway.Setup.Models;

namespace Gateway.Setup.Services;

internal sealed record AzureAccountDiscoveryResult(
    IReadOnlyList<AzureSubscription> Subscriptions,
    string? Guidance)
{
    public bool Succeeded => Guidance is null;
}

internal interface IAzureAccountDiscovery
{
    Task<AzureAccountDiscoveryResult> DiscoverAsync(CancellationToken cancellationToken = default);
}

internal sealed class AzureAccountDiscovery : IAzureAccountDiscovery
{
    private const int MaximumOutputCharacters = 256 * 1024;

    public async Task<AzureAccountDiscoveryResult> DiscoverAsync(
        CancellationToken cancellationToken = default)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = "az",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        foreach (var argument in new[]
        {
            "account",
            "list",
            "--query",
            "[].{name:name,id:id,tenantId:tenantId,isDefault:isDefault,state:state}",
            "--output",
            "json",
            "--only-show-errors"
        })
        {
            startInfo.ArgumentList.Add(argument);
        }

        startInfo.Environment["AZURE_CORE_NO_COLOR"] = "1";
        using var process = new Process { StartInfo = startInfo };
        try
        {
            if (!process.Start())
            {
                return MissingCli();
            }
        }
        catch (Exception exception) when (
            exception is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return MissingCli();
        }

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        var outputTask = ReadBoundedAsync(process.StandardOutput, timeout.Token);
        var errorTask = ReadBoundedAsync(process.StandardError, timeout.Token);

        try
        {
            await process.WaitForExitAsync(timeout.Token);
            var output = await outputTask;
            _ = await errorTask;
            if (process.ExitCode != 0)
            {
                return LoginGuidance();
            }

            var subscriptions = ParseSubscriptions(output);
            return subscriptions.Count == 0
                ? LoginGuidance()
                : new AzureAccountDiscoveryResult(subscriptions, null);
        }
        catch (OperationCanceledException)
        {
            try
            {
                if (!process.HasExited)
                {
                    process.Kill(entireProcessTree: true);
                }
            }
            catch (InvalidOperationException)
            {
                // Process already exited.
            }

            return new AzureAccountDiscoveryResult(
                [],
                "Azure account discovery timed out. Run `az account list` in the terminal, then try again.");
        }
        catch (JsonException)
        {
            return new AzureAccountDiscoveryResult(
                [],
                "Azure CLI returned an unexpected account inventory. Update Azure CLI and try again.");
        }
    }

    private static List<AzureSubscription> ParseSubscriptions(string json)
    {
        using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 6 });
        if (document.RootElement.ValueKind != JsonValueKind.Array)
        {
            throw new JsonException("Expected an array.");
        }

        var subscriptions = new List<AzureSubscription>();
        foreach (var item in document.RootElement.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object ||
                !Guid.TryParse(ReadString(item, "id"), out var subscriptionId) ||
                subscriptionId == Guid.Empty ||
                !Guid.TryParse(ReadString(item, "tenantId"), out var tenantId) ||
                tenantId == Guid.Empty)
            {
                continue;
            }

            var name = ReadString(item, "name")?.Trim();
            if (string.IsNullOrWhiteSpace(name) || name.Length > 100 || !SafePublicValuePolicy.IsAllowed(name))
            {
                name = "Azure subscription";
            }

            var state = ReadString(item, "state") ?? "Unknown";
            var isDefault = item.TryGetProperty("isDefault", out var defaultElement) &&
                defaultElement.ValueKind is JsonValueKind.True;
            subscriptions.Add(new AzureSubscription(subscriptionId, tenantId, name, isDefault, state));
        }

        return subscriptions
            .OrderByDescending(subscription => subscription.IsDefault)
            .ThenBy(subscription => subscription.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static string? ReadString(JsonElement item, string name) =>
        item.TryGetProperty(name, out var element) && element.ValueKind == JsonValueKind.String
            ? element.GetString()
            : null;

    private static async Task<string> ReadBoundedAsync(
        StreamReader reader,
        CancellationToken cancellationToken)
    {
        var buffer = new char[4 * 1024];
        var builder = new StringBuilder();
        while (true)
        {
            var count = await reader.ReadAsync(buffer.AsMemory(), cancellationToken);
            if (count == 0)
            {
                return builder.ToString();
            }

            if (builder.Length + count > MaximumOutputCharacters)
            {
                throw new JsonException("Azure CLI output exceeded the safe bound.");
            }

            builder.Append(buffer, 0, count);
        }
    }

    private static AzureAccountDiscoveryResult MissingCli() => new(
        [],
        "Azure CLI is not installed or not on PATH. Run `gateway doctor` or install Azure CLI, then try again.");

    private static AzureAccountDiscoveryResult LoginGuidance() => new(
        [],
        "No usable Azure subscriptions were found. Run `az login` in the terminal; Setup never asks for or stores your password or token.");
}
