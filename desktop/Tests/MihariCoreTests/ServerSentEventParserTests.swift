import Testing

@testable import MihariCore

@Suite("SSE のフレーム組み立て")
struct ServerSentEventParserTests {

    /// 行の並びを食わせて、組み上がったフレームを全部返す。
    private func parse(_ lines: [String]) -> [ServerSentEventParser.Frame] {
        var parser = ServerSentEventParser()
        return lines.compactMap { parser.consume(line: $0) }
    }

    @Test("空行までを 1 フレームとして組み立てる")
    func buildsFrameOnBlankLine() {
        let frames = parse(["event: ping", "data: {\"a\":1}", ""])
        #expect(frames == [ServerSentEventParser.Frame(event: "ping", data: "{\"a\":1}")])
    }

    @Test("空行が来るまではフレームを吐かない")
    func waitsForBlankLine() {
        #expect(parse(["event: ping", "data: {}"]).isEmpty)
    }

    @Test("keepalive のコメント行は捨てる")
    func ignoresComments() {
        // デーモンは無音時に ": keepalive" を送ってくる。これをイベントにしてはいけない。
        #expect(parse([": keepalive", ""]).isEmpty)
    }

    @Test("event 行がなくても data だけでフレームになる")
    func dataOnlyFrame() {
        let frames = parse(["data: hello", ""])
        #expect(frames == [ServerSentEventParser.Frame(event: nil, data: "hello")])
    }

    @Test("data 行が複数あれば改行で連結する")
    func joinsMultipleDataLines() {
        let frames = parse(["data: one", "data: two", ""])
        #expect(frames.first?.data == "one\ntwo")
    }

    @Test("コロン直後の空白は 1 つだけ取り除く")
    func stripsOnlyOneLeadingSpace() {
        #expect(parse(["data:  padded", ""]).first?.data == " padded")
        #expect(parse(["data:tight", ""]).first?.data == "tight")
    }

    @Test("フレームを吐いたあとは状態が残らない")
    func resetsBetweenFrames() {
        var parser = ServerSentEventParser()
        _ = parser.consume(line: "event: first")
        _ = parser.consume(line: "data: 1")
        _ = parser.consume(line: "")

        _ = parser.consume(line: "data: 2")
        let second = parser.consume(line: "")

        // 直前の event 名を引きずらないこと。
        #expect(second == ServerSentEventParser.Frame(event: nil, data: "2"))
    }

    @Test("行末の CR を落とす")
    func stripsCarriageReturn() {
        let frames = parse(["data: hello\r", "\r"])
        #expect(frames.first?.data == "hello")
    }
}
