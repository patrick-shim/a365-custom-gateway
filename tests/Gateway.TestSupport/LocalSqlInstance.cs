using System.Diagnostics;
using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;

namespace Gateway.TestSupport;

public sealed class LocalSqlInstance : IAsyncDisposable
{
    public const string ToolPath = @"C:\Program Files\Microsoft SQL Server\160\Tools\Binn\SqlLocalDB.exe";
    private readonly List<LocalSqlDatabase> _databases = [];
    private bool _ownsInstance;
    private bool _disposed;

    private LocalSqlInstance() => Name = $"m1_test_{Guid.NewGuid():N}";

    public string Name { get; }
    public string PipeName { get; private set; } = string.Empty;

    public static async Task<LocalSqlInstance> CreateAsync()
    {
        if (!OperatingSystem.IsWindows() || !File.Exists(ToolPath))
            throw new InvalidOperationException(
                $"SQL tests require Windows and SQL Server 2022 LocalDB at '{ToolPath}'. They are not skipped or replaced by InMemory.");

        var instance = new LocalSqlInstance();
        await RunToolAsync("create", instance.Name, "16.0");
        instance._ownsInstance = true;
        try
        {
            await RunToolAsync("start", instance.Name);
            var information = await RunToolAsync("info", instance.Name);
            var pipe = Regex.Match(information, @"np:\\\\\.\\pipe\\LOCALDB#[0-9A-Fa-f]+\\tsql\\query");
            if (!pipe.Success)
                throw new InvalidOperationException("The owned LocalDB instance did not publish an exact machine-local pipe.");
            instance.PipeName = pipe.Value;
            LocalSqlConnectionGuard.ValidateOwnedPipe(instance.PipeName);
            // Directly using the owned pipe avoids loading x64 SQLUserInstance.dll into an ARM64 test host.
            await using var connection = new SqlConnection(LocalSqlConnectionGuard.MasterConnectionString(instance.Name, instance.PipeName));
            await connection.OpenAsync();
            await using var command = connection.CreateCommand();
            command.CommandText = "SELECT CONVERT(int, SERVERPROPERTY('IsLocalDB'));";
            if (Convert.ToInt32(await command.ExecuteScalarAsync()) != 1)
                throw new InvalidOperationException("The SQL test connection is not LocalDB.");
            return instance;
        }
        catch
        {
            await instance.DisposeAsync();
            throw;
        }
    }

    public async Task<LocalSqlDatabase> CreateDatabaseAsync()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var database = await LocalSqlDatabase.CreateOwnedAsync(this);
        _databases.Add(database);
        return database;
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
            return;
        _disposed = true;
        var failures = new List<Exception>();
        foreach (var database in _databases)
        {
            try { await database.DisposeAsync(); }
            catch (Exception exception) { failures.Add(exception); }
        }
        if (_ownsInstance)
        {
            try { await RunToolAsync("stop", Name); }
            catch (Exception exception) { failures.Add(exception); }
            try { await RunToolAsync("delete", Name); }
            catch (Exception exception) { failures.Add(exception); }
        }
        if (failures.Count != 0)
            throw new AggregateException("Owned LocalDB cleanup failed; no shared instance was stopped.", failures);
    }

    private static async Task<string> RunToolAsync(params string[] arguments)
    {
        var start = new ProcessStartInfo(ToolPath)
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        foreach (var argument in arguments)
            start.ArgumentList.Add(argument);
        using var process = Process.Start(start)
            ?? throw new InvalidOperationException("Could not start the installed LocalDB tool.");
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(60));
        try
        {
            await process.WaitForExitAsync(timeout.Token);
        }
        catch (OperationCanceledException)
        {
            process.Kill(entireProcessTree: true);
            throw new TimeoutException("The bounded LocalDB prerequisite/cleanup command timed out.");
        }
        if (process.ExitCode != 0)
            throw new InvalidOperationException(
                $"LocalDB {arguments[0]} failed ({process.ExitCode}): {await error} {await output}");
        await Task.WhenAll(output, error);
        return await output;
    }
}
