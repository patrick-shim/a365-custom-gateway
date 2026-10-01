using System.Buffers.Binary;

namespace Gateway.Application.Agents.Queries;

public static class ListAgentsCursor
{
    private const byte Version = 1;
    private const int PayloadLength = 25;
    private const int EncodedLength = 34;

    public const string InvalidMessage = "The agent cursor is invalid. Restart the list without a cursor.";

    public static string Encode(DateTime createdAtUtc, Guid id)
    {
        Span<byte> payload = stackalloc byte[PayloadLength];
        payload[0] = Version;
        BinaryPrimitives.WriteInt64BigEndian(payload[1..9], createdAtUtc.Ticks);
        id.TryWriteBytes(payload[9..]);
        return Convert.ToBase64String(payload).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }

    public static bool TryDecode(string? cursor, out DateTime createdAtUtc, out Guid id)
    {
        createdAtUtc = default;
        id = default;
        if (cursor is null || cursor.Length != EncodedLength ||
            cursor.Any(character => !char.IsAsciiLetterOrDigit(character) && character is not '-' and not '_'))
            return false;

        Span<byte> payload = stackalloc byte[PayloadLength];
        if (!Convert.TryFromBase64String(cursor.Replace('-', '+').Replace('_', '/') + "==", payload, out var length) ||
            length != PayloadLength || payload[0] != Version)
            return false;

        var ticks = BinaryPrimitives.ReadInt64BigEndian(payload[1..9]);
        if (ticks < DateTime.MinValue.Ticks || ticks > DateTime.MaxValue.Ticks)
            return false;

        var parsedDate = new DateTime(ticks, DateTimeKind.Utc);
        var parsedId = new Guid(payload[9..]);
        if (parsedId == Guid.Empty || !string.Equals(Encode(parsedDate, parsedId), cursor, StringComparison.Ordinal))
            return false;

        createdAtUtc = parsedDate;
        id = parsedId;
        return true;
    }
}
