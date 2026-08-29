import Testing

@testable import MihariCore

@Suite("バイト列の行切り出し")
struct LineAccumulatorTests {

    private func lines(of text: String) -> [String] {
        var accumulator = LineAccumulator()
        return Array(text.utf8).compactMap { accumulator.consume(byte: $0) }
    }

    @Test("改行ごとに 1 行返す")
    func splitsOnNewline() {
        #expect(lines(of: "a\nbb\n") == ["a", "bb"])
    }

    @Test("空行を捨てない")
    func keepsEmptyLines() {
        // Foundation の bytes.lines はここで空行を捨てるため使えない。
        // SSE はフレームの区切りが空行なので、落とすとイベントが永久に完成しない。
        #expect(lines(of: "a\n\nb\n") == ["a", "", "b"])
    }

    @Test("SSE のフレーム 1 件分を行に分解できる")
    func splitsSSEFrame() {
        #expect(lines(of: "event: ping\ndata: {}\n\n") == ["event: ping", "data: {}", ""])
    }

    @Test("改行が来るまでは何も返さない")
    func waitsForNewline() {
        #expect(lines(of: "no newline yet").isEmpty)
    }

    @Test("マルチバイト文字が改行をまたいでも壊れない")
    func handlesMultibyte() {
        #expect(lines(of: "こんにちは\n世界\n") == ["こんにちは", "世界"])
    }
}
