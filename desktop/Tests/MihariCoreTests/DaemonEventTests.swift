import Foundation
import Testing

@testable import MihariCore

@Suite("デーモンから届くイベント")
struct DaemonEventTests {

    private func decode(_ json: String) throws -> DaemonEvent {
        try JSONDecoder().decode(DaemonEvent.self, from: Data(json.utf8))
    }

    @Test("name / payload / created_at を読む")
    func decodesEvent() throws {
        let event = try decode(
            #"{"name":"watch.start","payload":{"at":"19:00"},"created_at":"2026-08-29T04:00:00.123456+00:00"}"#
        )
        #expect(event.name == "watch.start")
        #expect(event.payload == ["at": "19:00"])
    }

    @Test("payload の数値や真偽値も表示用の文字列にする")
    func flattensPayloadValues() throws {
        let event = try decode(
            #"{"name":"x","payload":{"n":1,"ok":true,"nothing":null},"created_at":"2026-08-29T04:00:00.000001+00:00"}"#
        )
        #expect(event.payload["n"] == "1")
        #expect(event.payload["ok"] == "true")
        #expect(event.payload["nothing"] == "null")
    }

    @Test("payload が空でも読める")
    func emptyPayload() throws {
        let event = try decode(#"{"name":"connected","payload":{},"created_at":"2026-08-29T04:00:00.000001+00:00"}"#)
        #expect(event.payload.isEmpty)
    }

    @Test("マイクロ秒が 0 で小数部が省略された時刻も読める")
    func parsesTimestampWithoutFraction() {
        // Python の datetime.isoformat() はマイクロ秒がちょうど 0 のとき小数部を出さない。
        #expect(DaemonEvent.parseTimestamp("2026-08-29T04:00:00+00:00") != nil)
        #expect(DaemonEvent.parseTimestamp("2026-08-29T04:00:00.123456+00:00") != nil)
        #expect(DaemonEvent.parseTimestamp("まったく時刻ではない") == nil)
    }
}
