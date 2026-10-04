using System.Text.Json;
using System.Text.Json.Serialization;

namespace Gateway.Contracts.Serialization;

// Gateway DateTime contracts represent UTC instants. JSON offsets must not
// produce Local values, which Npgsql correctly refuses for timestamptz columns.
public sealed class UtcDateTimeJsonConverter : JsonConverter<DateTime>
{
    public override DateTime Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        Normalize(reader.GetDateTime());

    public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions options) =>
        writer.WriteStringValue(Normalize(value));

    private static DateTime Normalize(DateTime value) => value.Kind switch
    {
        DateTimeKind.Local => value.ToUniversalTime(),
        DateTimeKind.Unspecified => DateTime.SpecifyKind(value, DateTimeKind.Utc),
        _ => value
    };
}
