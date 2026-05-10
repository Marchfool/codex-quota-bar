import Foundation

public enum DateCoding {
    public static func parseISO8601(_ value: String) -> Date? {
        makeISO8601Formatter(fractionalSeconds: true).date(from: value)
            ?? makeISO8601Formatter(fractionalSeconds: false).date(from: value)
    }

    public static func formatISO8601(_ date: Date) -> String {
        makeISO8601Formatter(fractionalSeconds: true).string(from: date)
    }

    private static func makeISO8601Formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter
    }

    public static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = parseISO8601(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date: \(value)")
        }
        return decoder
    }

    public static var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatISO8601(date))
        }
        return encoder
    }
}
