using System.Text;

namespace Gateway.Setup.Services;

internal sealed class BootstrapProcessOutputBudget
{
    internal const int MaximumCharacters = 2 * 1024 * 1024;
    internal const int MaximumEvents = 2_048;

    private readonly object gate = new();
    private int remainingCharacters = MaximumCharacters;
    private int remainingEvents = MaximumEvents;
    private bool exhausted;
    private bool noticeEmitted;

    public int ClaimCharacters(int requested)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(requested);

        lock (gate)
        {
            if (exhausted || requested == 0)
            {
                return 0;
            }

            var granted = Math.Min(requested, remainingCharacters);
            remainingCharacters -= granted;
            if (granted < requested)
            {
                exhausted = true;
            }

            return granted;
        }
    }

    public bool TryClaimEvent()
    {
        lock (gate)
        {
            if (exhausted)
            {
                return false;
            }

            if (remainingEvents == 0)
            {
                exhausted = true;
                return false;
            }

            remainingEvents--;
            return true;
        }
    }

    public bool TryMarkNoticeEmitted()
    {
        lock (gate)
        {
            if (noticeEmitted)
            {
                return false;
            }

            noticeEmitted = true;
            return true;
        }
    }
}

internal static class BoundedProcessOutputReader
{
    internal const int MaximumLineCharacters = 4_096;
    private const int ReadBufferCharacters = 2_048;

    public static async Task ConsumeAsync(
        TextReader reader,
        bool standardError,
        BootstrapProcessOutputBudget budget,
        Func<BootstrapProgressEvent, ValueTask> onProgress,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(reader);
        ArgumentNullException.ThrowIfNull(budget);
        ArgumentNullException.ThrowIfNull(onProgress);

        var buffer = new char[ReadBufferCharacters];
        var line = new StringBuilder(Math.Min(MaximumLineCharacters, ReadBufferCharacters));
        var lineOversized = false;

        while (true)
        {
            var read = await reader.ReadAsync(buffer.AsMemory(), cancellationToken);
            if (read == 0)
            {
                if (!lineOversized && line.Length == 0)
                {
                    return;
                }

                await EmitLineAsync();
                return;
            }

            var granted = budget.ClaimCharacters(read);
            for (var index = 0; index < granted; index++)
            {
                var character = buffer[index];
                if (character == '\r')
                {
                    continue;
                }

                if (character == '\n')
                {
                    await EmitLineAsync();
                    line.Clear();
                    lineOversized = false;
                    continue;
                }

                if (line.Length < MaximumLineCharacters)
                {
                    line.Append(character);
                }
                else
                {
                    lineOversized = true;
                }
            }

            if (granted < read)
            {
                line.Clear();
                lineOversized = false;
                await EmitBudgetNoticeAsync();
            }

            async ValueTask EmitLineAsync()
            {
                if (!budget.TryClaimEvent())
                {
                    await EmitBudgetNoticeAsync();
                    return;
                }

                var progress = lineOversized
                    ? new BootstrapProgressEvent(
                        DateTimeOffset.UtcNow,
                        BootstrapProgressKind.Withheld,
                        BootstrapOutputSanitizer.WithheldMessage)
                    : BootstrapOutputSanitizer.Parse(line.ToString(), standardError);
                await onProgress(progress);
            }

            async ValueTask EmitBudgetNoticeAsync()
            {
                if (budget.TryMarkNoticeEmitted())
                {
                    await onProgress(new BootstrapProgressEvent(
                        DateTimeOffset.UtcNow,
                        BootstrapProgressKind.Withheld,
                        BootstrapOutputSanitizer.StreamBudgetMessage));
                }
            }
        }
    }
}
