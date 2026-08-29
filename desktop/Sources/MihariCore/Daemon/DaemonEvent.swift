import Foundation

/// Python 側から SSE で届く 1 件のイベント。
public struct DaemonEvent: Decodable, Equatable, Sendable, Identifiable {
    public let name: String
    public let payload: [String: String]
    public let createdAt: Date

    public var id: String { "\(createdAt.timeIntervalSince1970)-\(name)" }

    enum CodingKeys: String, CodingKey {
        case name
        case payload
        case createdAt = "created_at"
    }

    public init(name: String, payload: [String: String] = [:], createdAt: Date = Date()) {
        self.name = name
        self.payload = payload
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        // payload の値は任意の JSON になりうるので、表示用に文字列へ潰す。
        let raw = try container.decodeIfPresent([String: AnyCodableValue].self, forKey: .payload) ?? [:]
        payload = raw.mapValues(\.displayText)

        let text = try container.decode(String.self, forKey: .createdAt)
        guard let date = Self.parseTimestamp(text) else {
            throw DecodingError.dataCorruptedError(
                forKey: .createdAt,
                in: container,
                debugDescription: "ISO8601 として解釈できない: \(text)"
            )
        }
        createdAt = date
    }

    /// Python の `datetime.isoformat()` を解釈する。
    ///
    /// マイクロ秒がちょうど 0 のときだけ小数部が省略されるため、両方の形式を試す。
    /// ISO8601DateFormatter は Sendable ではないので、共有せずその場で作る。
    static func parseTimestamp(_ text: String) -> Date? {
        for options in [
            ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds]),
            ISO8601DateFormatter.Options([.withInternetDateTime]),
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) {
                return date
            }
        }
        return nil
    }
}

/// payload に何が入っていても落ちずに表示できるようにするための入れ物。
struct AnyCodableValue: Decodable {
    let displayText: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            displayText = value
        } else if let value = try? container.decode(Int.self) {
            displayText = String(value)
        } else if let value = try? container.decode(Double.self) {
            displayText = String(value)
        } else if let value = try? container.decode(Bool.self) {
            displayText = String(value)
        } else if container.decodeNil() {
            displayText = "null"
        } else {
            displayText = "(未対応の値)"
        }
    }
}
