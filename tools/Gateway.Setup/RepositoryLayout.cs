namespace Gateway.Setup;

internal sealed record RepositoryLayout(string RootPath)
{
    public string BootstrapScriptPath => Path.Combine(RootPath, "bootstrap", "bootstrap.ps1");

    public string BootstrapConfigPath => Path.Combine(RootPath, "bootstrap", "config.json");

    public static RepositoryLayout Resolve(string? requestedRoot)
    {
        var start = string.IsNullOrWhiteSpace(requestedRoot)
            ? Directory.GetCurrentDirectory()
            : requestedRoot;
        var directory = new DirectoryInfo(Path.GetFullPath(start));

        while (directory is not null)
        {
            var bootstrapScript = Path.Combine(directory.FullName, "bootstrap", "bootstrap.ps1");
            var solution = Path.Combine(directory.FullName, "src", "A365Gateway.slnx");
            if (File.Exists(bootstrapScript) && File.Exists(solution))
            {
                return new RepositoryLayout(directory.FullName);
            }

            directory = directory.Parent;
        }

        throw new InvalidOperationException(
            "Gateway Setup must run from a complete A365 Custom Gateway repository checkout. " +
            "Run it from the repository root or pass --repo-root with that public filesystem path.");
    }
}
