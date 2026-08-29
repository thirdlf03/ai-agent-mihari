import Foundation

/// SSE のバイト列を 1 フレームずつ組み立てる。
///
/// 行を順に食わせ、空行が来たところで 1 件のフレームとして吐き出す。
/// `:` で始まる行は keepalive のコメントなので捨てる。
public struct ServerSentEventParser {

    /// 組み上がったフレーム 1 件。
    public struct Frame: Equatable, Sendable {
        public let event: String?
        public let data: String
    }

    private var eventName: String?
    private var dataLines: [String] = []

    public init() {}

    /// 1 行を食わせる。フレームが完成したら返す。
    public mutating func consume(line: String) -> Frame? {
        // URLSession の lines は改行を含まないが、生バイトを分割した場合に備えて落とす。
        let line = line.hasSuffix("\r") ? String(line.dropLast()) : line

        if line.isEmpty {
            defer {
                eventName = nil
                dataLines = []
            }
            guard !dataLines.isEmpty else { return nil }
            return Frame(event: eventName, data: dataLines.joined(separator: "\n"))
        }

        if line.hasPrefix(":") {
            return nil
        }

        if let value = Self.value(of: "event", in: line) {
            eventName = value
        } else if let value = Self.value(of: "data", in: line) {
            dataLines.append(value)
        }
        return nil
    }

    private static func value(of field: String, in line: String) -> String? {
        guard line.hasPrefix("\(field):") else { return nil }
        let raw = line.dropFirst(field.count + 1)
        // 仕様上、コロンの直後の空白 1 つだけを取り除く。
        return raw.hasPrefix(" ") ? String(raw.dropFirst()) : String(raw)
    }
}
