import Foundation

/// The JSON coding the host speaks: snake_case keys and RFC 3339 instants, which Go writes
/// with up to nine fractional digits and none when the fraction is zero.
public enum WireCoding {
  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let raw = try container.decode(String.self)
      guard let date = parseDate(raw) else {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "not an RFC 3339 instant: \(raw)")
      }
      return date
    }
    return decoder
  }

  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(formatDate(date))
    }
    return encoder
  }

  public static func parseDate(_ raw: String) -> Date? {
    if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw) {
      return date
    }
    return try? Date.ISO8601FormatStyle().parse(raw)
  }

  public static func formatDate(_ date: Date) -> String {
    let whole = date.timeIntervalSinceReferenceDate.rounded(.down)
    if whole == date.timeIntervalSinceReferenceDate {
      return date.formatted(.iso8601)
    }
    return date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
  }
}
