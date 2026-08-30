import Foundation
import Testing

@testable import MihariCore

@Suite("stderr の行切り出し")
struct DaemonStderrLogTests {

    private func data(_ text: String) -> Data {
        Data(text.utf8)
    }

    @Test("改行ごとに 1 行返す")
    func splitsOnNewline() {
        var log = DaemonStderrLog()
        #expect(log.consume(chunk: data("a\nbb\n")) == ["a", "bb"])
    }

    @Test("行の途中で切れたチャンクは改行が来るまで溜める")
    func buffersPartialLine() {
        var log = DaemonStderrLog()
        #expect(log.consume(chunk: data("ERROR: 途中")).isEmpty)
        #expect(log.consume(chunk: data("で切れた\n")) == ["ERROR: 途中で切れた"])
    }

    @Test("EOF に残った端数を flush で取り出せる")
    func flushesLeftover() {
        var log = DaemonStderrLog()
        _ = log.consume(chunk: data("done\nまだ改行なし"))
        #expect(log.flush() == "まだ改行なし")
        #expect(log.flush() == nil)
    }

    @Test("直近の行だけを上限まで残す")
    func keepsRecentLines() {
        var log = DaemonStderrLog(capacity: 2)
        _ = log.consume(chunk: data("1\n2\n3\n"))
        #expect(log.recentLines == ["2", "3"])
        #expect(log.recentText == "2\n3")
    }

    @Test("行末の CR を落とす")
    func stripsCarriageReturn() {
        var log = DaemonStderrLog()
        #expect(log.consume(chunk: data("a\r\nb\r\n")) == ["a", "b"])
    }

    @Test("マルチバイト文字がチャンクをまたいでも壊れない")
    func handlesMultibyteAcrossChunks() {
        var log = DaemonStderrLog()
        let bytes = Array("あい\n".utf8)
        #expect(log.consume(chunk: Data(bytes[..<2])).isEmpty)
        #expect(log.consume(chunk: Data(bytes[2...])) == ["あい"])
    }
}
