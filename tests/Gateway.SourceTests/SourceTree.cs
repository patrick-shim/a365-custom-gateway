namespace Gateway.SourceTests;

internal static class SourceTree
{
    private static readonly HashSet<string> ExcludedDirectories = new(StringComparer.OrdinalIgnoreCase)
    {
        ".git", ".azure", ".bootstrap", ".maintenance", ".copilot-azure",
        ".test-work", ".vs", "bin", "obj", "TestResults", "node_modules", "__pycache__"
    };

    internal static string Root { get; } = FindRoot();

    internal static string Resolve(params string[] segments) =>
        Path.Combine([Root, .. segments]);

    internal static IEnumerable<string> Files(string extension)
    {
        var pending = new Stack<string>();
        pending.Push(Root);
        while (pending.TryPop(out var directory))
        {
            foreach (var entry in new DirectoryInfo(directory).EnumerateFileSystemInfos())
            {
                if (entry.Attributes.HasFlag(FileAttributes.ReparsePoint))
                    continue;
                if (entry is DirectoryInfo child)
                {
                    if (!ExcludedDirectories.Contains(child.Name))
                        pending.Push(child.FullName);
                }
                else if (string.Equals(entry.Extension, extension, StringComparison.OrdinalIgnoreCase))
                {
                    yield return entry.FullName;
                }
            }
        }
    }

    private static string FindRoot()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory);
             directory is not null; directory = directory.Parent)
        {
            if (File.Exists(Path.Combine(directory.FullName, "MILESTONES.md")) &&
                File.Exists(Path.Combine(directory.FullName, "global.json")))
                return directory.FullName;
        }
        throw new InvalidOperationException("Tests require the authored source tree, not an old binary-only output.");
    }
}
