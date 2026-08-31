using FluentAssertions;

namespace Gateway.Setup.Tests;

public sealed class RepositoryLayoutTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"gateway-setup-layout-{Guid.NewGuid():N}");

    [Fact]
    public void Resolve_AcceptsCompletePublicCheckoutWithoutLocalDevelopmentFiles()
    {
        WritePublicCheckoutMarkers();
        var normalizedWindowsLauncherRoot = Path.Combine(root, ".");

        var result = RepositoryLayout.Resolve(normalizedWindowsLauncherRoot);

        result.RootPath.Should().Be(Path.GetFullPath(root));
    }

    [Fact]
    public void Resolve_SearchesParentsFromARepositorySubdirectory()
    {
        WritePublicCheckoutMarkers();
        var child = Directory.CreateDirectory(Path.Combine(root, "tools", "Gateway.Setup"));

        var result = RepositoryLayout.Resolve(child.FullName);

        result.RootPath.Should().Be(Path.GetFullPath(root));
    }

    [Fact]
    public void Resolve_RejectsCheckoutMissingEitherPublicMarker()
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        File.WriteAllText(Path.Combine(root, "bootstrap", "bootstrap.ps1"), string.Empty);

        var act = () => RepositoryLayout.Resolve(root);

        act.Should().Throw<InvalidOperationException>()
            .WithMessage("*complete A365 Custom Gateway repository checkout*");
    }

    private void WritePublicCheckoutMarkers()
    {
        Directory.CreateDirectory(Path.Combine(root, "bootstrap"));
        Directory.CreateDirectory(Path.Combine(root, "src"));
        File.WriteAllText(Path.Combine(root, "bootstrap", "bootstrap.ps1"), string.Empty);
        File.WriteAllText(Path.Combine(root, "src", "A365Gateway.slnx"), string.Empty);
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
