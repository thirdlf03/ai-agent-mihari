import Foundation

/// 連続で届いたセリフを順番に吹き出しへ流すためのキュー。
///
/// - 直前と全く同じセリフが連続で来たときは積み増さない（同じ小言を二度並べても意味がないため）。
/// - 溜まりすぎないよう上限を超えたら古いものから捨てる。
public struct PetSpeechQueue: Sendable, Equatable {
    /// 溜め込める件数の上限。これを超えたら古いものから捨てる。
    public static let capacity = 5

    public private(set) var lines: [String] = []

    public init() {}

    public var isEmpty: Bool { lines.isEmpty }
    public var count: Int { lines.count }

    /// セリフを末尾に積む。空文字と、直前と同じセリフの連投は無視する。
    @discardableResult
    public mutating func enqueue(_ line: String) -> Bool {
        guard !line.isEmpty, lines.last != line else { return false }
        lines.append(line)
        if lines.count > Self.capacity {
            lines.removeFirst(lines.count - Self.capacity)
        }
        return true
    }

    /// 先頭のセリフを取り出す。無ければ `nil`。
    public mutating func dequeue() -> String? {
        guard !lines.isEmpty else { return nil }
        return lines.removeFirst()
    }
}
