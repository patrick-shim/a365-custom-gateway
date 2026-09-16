using FluentAssertions;
using Gateway.Setup.Services;

namespace Gateway.Setup.Tests.Services;

public sealed class BoundedProcessOutputReaderTests
{
    [Fact]
    public async Task OversizedLine_IsDiscardedWithoutRenderingItsContents()
    {
        const string sentinel = "credential-sentinel-must-not-render";
        var input = string.Concat(
            new string('a', BoundedProcessOutputReader.MaximumLineCharacters),
            sentinel,
            Environment.NewLine);
        var events = new List<BootstrapProgressEvent>();

        await BoundedProcessOutputReader.ConsumeAsync(
            new StringReader(input),
            standardError: false,
            new BootstrapProcessOutputBudget(),
            progress =>
            {
                events.Add(progress);
                return ValueTask.CompletedTask;
            },
            CancellationToken.None);

        events.Should().ContainSingle();
        events[0].Kind.Should().Be(BootstrapProgressKind.Withheld);
        events[0].Message.Should().Be(BootstrapOutputSanitizer.WithheldMessage);
        events.Should().NotContain(progress => progress.Message.Contains(sentinel, StringComparison.Ordinal));
    }

    [Fact]
    public async Task OversizedCombinedStream_EmitsOneFixedBudgetNoticeAndDrainsTheRest()
    {
        const string sentinel = "provider-body-sentinel-must-not-render";
        var input = string.Concat(
            new string('x', BootstrapProcessOutputBudget.MaximumCharacters),
            sentinel,
            Environment.NewLine,
            sentinel,
            Environment.NewLine);
        var events = new List<BootstrapProgressEvent>();

        await BoundedProcessOutputReader.ConsumeAsync(
            new StringReader(input),
            standardError: false,
            new BootstrapProcessOutputBudget(),
            progress =>
            {
                events.Add(progress);
                return ValueTask.CompletedTask;
            },
            CancellationToken.None);

        events.Count(progress => progress.Message == BootstrapOutputSanitizer.StreamBudgetMessage)
            .Should().Be(1);
        events.Should().NotContain(progress => progress.Message.Contains(sentinel, StringComparison.Ordinal));
    }

    [Fact]
    public async Task ExcessiveLineCount_IsBoundedEvenWhenTheCharacterBudgetRemains()
    {
        var input = string.Concat(Enumerable.Repeat("{}\n", BootstrapProcessOutputBudget.MaximumEvents + 20));
        var events = new List<BootstrapProgressEvent>();

        await BoundedProcessOutputReader.ConsumeAsync(
            new StringReader(input),
            standardError: false,
            new BootstrapProcessOutputBudget(),
            progress =>
            {
                events.Add(progress);
                return ValueTask.CompletedTask;
            },
            CancellationToken.None);

        events.Should().HaveCount(BootstrapProcessOutputBudget.MaximumEvents + 1);
        events[^1].Message.Should().Be(BootstrapOutputSanitizer.StreamBudgetMessage);
    }
}
