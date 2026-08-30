import Foundation
import Testing

@testable import MihariCore

/// 監視ループを実際に回して、放置すると発火するところまでを 1 本で確かめる。
///
/// 単体テストが個々の分岐を押さえているのに対し、ここは「ループが本当に回るか」だけを見る。
/// 無操作秒数を外から動かせる箱。`@Sendable` クロージャから読むのでロックで守る。
private final class IdleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    func set(_ seconds: TimeInterval) { lock.withLock { value = seconds } }
    func read() -> TimeInterval { lock.withLock { value } }
}

@Suite("監視ループ")
@MainActor
struct DetectionSmokeTests {

    @Test("監視を始めて放置すると、確定まで進んで証拠を取りに行く")
    func loopReachesConfirmed() async throws {
        let spy = ActionSpy()
        let idle = IdleClock()
        let engine = DetectionEngine(
            idleMonitor: MacIdleMonitor(probe: { idle.read() }),
            frontmostMonitor: FrontmostAppMonitor(probe: { "Xcode" })
        )
        engine.actions = spy.makeActions()
        // セリフを bridge に作らせる経路まで通す。同封音声のときは speak を呼ばない。
        engine.voiceMode = .live
        // ループの間隔は 5 秒なので、閾値を秒単位まで縮めて手で進める。
        engine.thresholds = DetectionThresholds(
            suspectSeconds: 1,
            confirmSeconds: 2,
            stampGraceSeconds: 0,
            cooldownSeconds: 100
        )
        engine.iphoneState = .unreachable

        idle.set(0)
        #expect(await engine.evaluate().state == .normal)

        idle.set(1)
        #expect(await engine.evaluate().state == .suspected)
        #expect(spy.spoken.count == 1)

        idle.set(3)
        let confirmed = await engine.evaluate()
        #expect(confirmed.state == .confirmed)
        #expect(confirmed.evidence == .macCamera)
        #expect(spy.macPhotos == 1)
        #expect(spy.posts.count == 1)

        // 記録に「なぜ撮られたか」が残っている。
        let entry = try #require(engine.log.first)
        #expect(entry.reason.contains("無操作"))
        #expect(entry.reason.contains("Xcode"))
    }

    @Test("iPhone を触っていると証拠の取り先が入れ替わる")
    func branchSwitchesWithPhoneState() async {
        let spy = ActionSpy()
        let engine = DetectionEngine(idleMonitor: MacIdleMonitor(probe: { 600 }))
        engine.actions = spy.makeActions()
        engine.thresholds = DetectionThresholds(suspectSeconds: 1, confirmSeconds: 2, cooldownSeconds: 0)

        engine.iphoneState = .unreachable
        await engine.evaluate()
        engine.iphoneState = .active
        await engine.evaluate()

        #expect(spy.macPhotos == 1)
        #expect(spy.iphoneShots == 1)
        #expect(spy.posts.map(\.2) == ["camera.png", "iphone.png"])
    }
}
