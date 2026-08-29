import Foundation

/// バイト列を 1 行ずつに切り出す。**空行も落とさずに返す。**
///
/// Foundation の `AsyncLineSequence`(`bytes.lines`)は空行を読み飛ばす。
/// SSE はフレームの区切りが空行なので、これを使うとフレームが永久に完成せず、
/// 接続は成功しているのにイベントが 1 件も届かない、という症状になる。
public struct LineAccumulator {

    private var buffer: [UInt8] = []

    public init() {}

    /// 1 バイト食わせる。行が終わったらその行を返す。
    public mutating func consume(byte: UInt8) -> String? {
        guard byte == UInt8(ascii: "\n") else {
            buffer.append(byte)
            return nil
        }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return line
    }
}
