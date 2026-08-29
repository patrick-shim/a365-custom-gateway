namespace Gateway.Setup;

internal sealed record SetupHostArguments(string? RepositoryRoot, bool OpenBrowser)
{
    public static SetupHostArguments Parse(IReadOnlyList<string> args)
    {
        string? repositoryRoot = null;
        var openBrowser = true;

        for (var index = 0; index < args.Count; index++)
        {
            switch (args[index])
            {
                case "--no-open":
                    openBrowser = false;
                    break;
                case "--repo-root" when index + 1 < args.Count:
                    repositoryRoot = args[++index];
                    break;
                default:
                    throw new ArgumentException(
                        $"Unsupported setup argument '{args[index]}'. Supported arguments are --repo-root <path> and --no-open.");
            }
        }

        return new SetupHostArguments(repositoryRoot, openBrowser);
    }
}
