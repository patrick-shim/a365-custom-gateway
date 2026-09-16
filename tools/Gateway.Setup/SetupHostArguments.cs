namespace Gateway.Setup;

internal sealed record SetupHostArguments(string? RepositoryRoot, bool OpenBrowser, bool ShowHelp = false)
{
    public const string Usage = """
        Usage: Gateway.Setup [--repo-root <path>] [--no-open] [--help]

          --repo-root <path>  Locate a complete Gateway repository checkout.
          --no-open           Print the one-time loopback URL without opening a browser.
          -h, --help          Show help without starting Setup or reading configuration.

        Authentication and deployment require separate explicit actions in Setup.
        """;

    public static SetupHostArguments Parse(IReadOnlyList<string> args)
    {
        ArgumentNullException.ThrowIfNull(args);
        string? repositoryRoot = null;
        var openBrowser = true;
        var showHelp = false;

        for (var index = 0; index < args.Count; index++)
        {
            switch (args[index])
            {
                case "--no-open":
                    openBrowser = false;
                    break;
                case "-h":
                case "--help":
                    showHelp = true;
                    break;
                case "--repo-root":
                    if (repositoryRoot is not null ||
                        index + 1 >= args.Count ||
                        string.IsNullOrWhiteSpace(args[index + 1]) ||
                        args[index + 1].StartsWith("--", StringComparison.Ordinal) ||
                        args[index + 1] == "-h")
                    {
                        throw new ArgumentException("--repo-root requires one public filesystem path and may be supplied only once.");
                    }

                    repositoryRoot = args[++index];
                    break;
                default:
                    throw new ArgumentException(
                        "Unsupported setup argument. Use --help for the supported options.");
            }
        }

        return new SetupHostArguments(repositoryRoot, openBrowser && !showHelp, showHelp);
    }
}
