import Foundation

/// 子プロセスの stderr を行に切り出し、直近ぶんだけ手元に残す。
///
/// stderr はチャンクで届き、行の途中で切れる。改行が来るまで溜めて、揃った行だけを返す。
/// 返した行は `capacity` 件まで保持し、起動に失敗した理由の表示に使う。
struct DaemonStderrLog {

    /// 手元に残す行数。古いものから捨てる。
    let capacity: Int

    private var buffer: [UInt8] = []

    /// 直近の行。新しいものが後ろ。
    private(set) var recentLines: [String] = []

    init(capacity: Int = 50) {
        self.capacity = max(1, capacity)
    }

    /// チャンクを 1 つ食わせる。改行まで揃った行だけを返す。
    mutating func consume(chunk: Data) -> [String] {
        buffer.append(contentsOf: chunk)
        var lines: [String] = []
        while let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(Self.line(from: buffer[..<index]))
            buffer.removeSubrange(...index)
        }
        remember(lines)
        return lines
    }

    /// EOF で残った、改行の付かない最後の行。無ければ `nil`。
    mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        let line = Self.line(from: buffer[...])
        buffer.removeAll()
        remember([line])
        return line
    }

    /// 直近の行をまとめたもの。
    var recentText: String {
        recentLines.joined(separator: "\n")
    }

    private mutating func remember(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        recentLines.append(contentsOf: lines)
        if recentLines.count > capacity {
            recentLines.removeFirst(recentLines.count - capacity)
        }
    }

    /// 行末の CR を落として文字列にする。改行の位置で切っているので、
    /// マルチバイト文字の途中で切れることはない。
    private static func line(from bytes: ArraySlice<UInt8>) -> String {
        var slice = bytes
        if slice.last == UInt8(ascii: "\r") {
            slice = slice.dropLast()
        }
        return String(decoding: slice, as: UTF8.self)
    }
}
