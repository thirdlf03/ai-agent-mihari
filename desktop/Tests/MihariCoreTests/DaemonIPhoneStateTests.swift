import Foundation
import Testing

@testable import MihariCore

@Suite("iPhone の状態を取り直す")
struct DaemonIPhoneStateTests {

    private func response(
        activity: String = "idle",
        udid: String? = nil,
        batteryLevel: Double? = nil,
        batteryCharging: Bool? = nil,
        updatedAt: String = "2026-08-29T12:00:00.000000+00:00"
    ) -> IPhoneStateResponse {
        IPhoneStateResponse(
            activity: activity,
            udid: udid,
            batteryLevel: batteryLevel,
            batteryCharging: batteryCharging,
            updatedAt: updatedAt
        )
    }

    private func stateEvent(at text: String) -> DaemonEvent {
        DaemonEvent(
            name: "iphone.state",
            payload: ["activity": "active"],
            createdAt: DaemonEvent.parseTimestamp(text)!
        )
    }

    @Test("まだ何も届いていなければ、そのままイベントにする")
    func buildsEventWhenNothingSeenYet() {
        let event = DaemonController.makeIPhoneStateEvent(from: response(), existing: [])

        #expect(event?.name == "iphone.state")
        #expect(event?.payload["activity"] == "idle")
        #expect(event?.createdAt == DaemonEvent.parseTimestamp("2026-08-29T12:00:00.000000+00:00"))
    }

    @Test("nil でない項目だけを SSE と同じキーで入れる")
    func payloadCarriesOptionalFields() {
        let full = DaemonController.makeIPhoneStateEvent(
            from: response(udid: "abc123", batteryLevel: 0.5, batteryCharging: true),
            existing: []
        )
        #expect(full?.payload["udid"] == "abc123")
        #expect(full?.payload["battery_level"] == "0.5")
        #expect(full?.payload["battery_charging"] == "true")

        let bare = DaemonController.makeIPhoneStateEvent(from: response(), existing: [])
        #expect(bare?.payload.keys.sorted() == ["activity"])
    }

    @Test("手元にあるものより新しければイベントにする")
    func newerSnapshotWins() {
        let event = DaemonController.makeIPhoneStateEvent(
            from: response(updatedAt: "2026-08-29T12:00:01.000000+00:00"),
            existing: [stateEvent(at: "2026-08-29T12:00:00.000000+00:00")]
        )

        #expect(event != nil)
    }

    @Test("古いスナップショットで新しい状態を上書きしない")
    func olderSnapshotIsDropped() {
        // GET は監視を起動した時点の初期値を返すので、SSE の方が先に届くことがある。
        let older = DaemonController.makeIPhoneStateEvent(
            from: response(activity: "unresponsive", updatedAt: "2026-08-29T11:59:59.000000+00:00"),
            existing: [stateEvent(at: "2026-08-29T12:00:00.000000+00:00")]
        )
        #expect(older == nil)
    }

    @Test("同じ時刻でも上書きしない")
    func sameTimestampIsDropped() {
        let same = DaemonController.makeIPhoneStateEvent(
            from: response(updatedAt: "2026-08-29T12:00:00.000000+00:00"),
            existing: [stateEvent(at: "2026-08-29T12:00:00.000000+00:00")]
        )
        #expect(same == nil)
    }

    @Test("iphone.state 以外のイベントは新しさの判定に使わない")
    func otherEventsAreIgnored() {
        let other = DaemonEvent(
            name: "test.ping",
            createdAt: DaemonEvent.parseTimestamp("2026-08-29T13:00:00.000000+00:00")!
        )
        let event = DaemonController.makeIPhoneStateEvent(from: response(), existing: [other])

        #expect(event != nil)
    }

    @Test("時刻を解釈できないときは何もしない")
    func unparsableTimestampIsDropped() {
        #expect(DaemonController.makeIPhoneStateEvent(from: response(updatedAt: "いつか"), existing: []) == nil)
    }

    @Test("応答の snake_case を読める")
    func decodesSnakeCaseKeys() throws {
        let json = """
            {
              "activity": "active",
              "udid": "abc123",
              "battery_level": 0.42,
              "battery_charging": false,
              "updated_at": "2026-08-29T12:00:00.000000+00:00"
            }
            """
        let decoded = try JSONDecoder().decode(IPhoneStateResponse.self, from: Data(json.utf8))

        #expect(decoded.activity == "active")
        #expect(decoded.udid == "abc123")
        #expect(decoded.batteryLevel == 0.42)
        #expect(decoded.batteryCharging == false)
        #expect(decoded.updatedAt == "2026-08-29T12:00:00.000000+00:00")
    }
}
