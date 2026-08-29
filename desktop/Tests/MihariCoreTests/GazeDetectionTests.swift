import Foundation
import Testing

@testable import MihariCore

@Suite("視線の見立て")
struct GazeStateTests {

    private func metrics(openness: Double, yaw: Double) -> FaceLandmarkMetrics {
        FaceLandmarkMetrics(leftEyeOpenness: openness, rightEyeOpenness: openness, yawRadians: yaw)
    }

    @Test("正面を向いて目が開いていれば、画面を見ている")
    func openEyesFacingForward() {
        #expect(GazeState.from(outcome: .faceFound(metrics(openness: 0.30, yaw: 0.0))) == .lookingAtScreen)
    }

    @Test("目が閉じていれば見ていない")
    func closedEyes() {
        #expect(GazeState.from(outcome: .faceFound(metrics(openness: 0.05, yaw: 0.0))) == .notLooking)
    }

    @Test("横を向いていれば見ていない")
    func lookingAway() {
        #expect(GazeState.from(outcome: .faceFound(metrics(openness: 0.30, yaw: 0.9))) == .notLooking)
    }

    @Test("誰も写っていなければ見ていない")
    func noFace() {
        #expect(GazeState.from(outcome: .noFaceFound) == .notLooking)
    }

    @Test("検出に失敗したときは「見ていない」と決めつけない")
    func detectionFailureIsUnknown() {
        // カメラが使えないだけで撮られては困る。分からないときは不明のままにする。
        #expect(GazeState.from(outcome: .detectionFailed(reason: "カメラが使えない")) == .unknown)
    }
}

@Suite("画面を見ていないときの判定")
struct NotLookingJudgeTests {

    private let judge = DetectionJudge(thresholds: .default)

    private func signals(idle: TimeInterval, gaze: GazeState) -> DetectionSignals {
        DetectionSignals(macIdleSeconds: idle, gaze: gaze)
    }

    @Test("無操作かつ画面を見ていないと、確定まで待たずに確定する")
    func notLookingConfirmsEarly() {
        // 既定では確定 300 秒だが、見ていないと分かっているなら 90 秒で確定させる。
        let decision = judge.decide(signals(idle: 100, gaze: .notLooking))
        #expect(decision.state == .confirmed)
        #expect(decision.evidence == .macCamera)
    }

    @Test("どちらの条件で引っかかったかが根拠に残る")
    func reasonNamesTheCause() {
        #expect(judge.decide(signals(idle: 100, gaze: .notLooking)).reason.contains("画面を見ていない"))
        #expect(!judge.decide(signals(idle: 400, gaze: .unknown)).reason.contains("画面を見ていない"))
    }

    @Test("画面を見ていても無操作が続けば、これまで通り時間で確定する")
    func lookingStillConfirmsOnTime() {
        #expect(judge.decide(signals(idle: 400, gaze: .lookingAtScreen)).state == .confirmed)
    }

    @Test("画面を見ている間は早期確定しない")
    func lookingIsNotConfirmedEarly() {
        // 資料を読んでいるだけで撮られては困る。
        #expect(judge.decide(signals(idle: 100, gaze: .lookingAtScreen)).state == .normal)
        #expect(judge.decide(signals(idle: 150, gaze: .lookingAtScreen)).state == .suspected)
    }

    @Test("視線が不明なら早期確定しない")
    func unknownGazeIsNotConfirmedEarly() {
        // カメラが使えないだけで撮られては困る。
        #expect(judge.decide(signals(idle: 100, gaze: .unknown)).state == .normal)
    }

    @Test("早期確定の境界は 90 秒ちょうどから")
    func notLookingBoundary() {
        #expect(judge.decide(signals(idle: 89, gaze: .notLooking)).state == .normal)
        #expect(judge.decide(signals(idle: 90, gaze: .notLooking)).state == .confirmed)
    }

    @Test("見ていなくても在席スタンプ直後なら見逃す")
    func stampStillWins() {
        let signals = DetectionSignals(macIdleSeconds: 200, gaze: .notLooking, secondsSinceStamp: 30)
        #expect(judge.decide(signals).state == .normal)
    }

    @Test("覗き始めるより手前で早期確定しないよう閾値が守られる")
    func gazeCheckNeverStartsAfterConfirmation() {
        // 覗く前に「見ていない」で確定させると、視線が必ず不明のままになって機能しない。
        let thresholds = DetectionThresholds(notLookingConfirmSeconds: 90, gazeCheckSeconds: 200)
        #expect(thresholds.gazeCheckSeconds <= thresholds.notLookingConfirmSeconds)
    }
}

@Suite("カメラを覗く条件")
@MainActor
struct GazePeekTests {

    /// 何回覗かれたかを数える。
    private final class GazeSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        var answer: GazeState = .notLooking

        func check() async -> GazeState {
            lock.withLock { _count += 1 }
            return answer
        }
    }

    private func engine(idle: TimeInterval, gaze: GazeSpy) -> DetectionEngine {
        let engine = DetectionEngine(idleMonitor: MacIdleMonitor(probe: { idle }))
        engine.actions = DetectionEngine.Actions(checkGaze: { await gaze.check() })
        return engine
    }

    @Test("手を動かしている間はカメラを一切起動しない")
    func neverPeeksWhileActive() async {
        // 緑ランプが点きっぱなしになると、ただの監視カメラになってしまう。
        let gaze = GazeSpy()
        _ = await engine(idle: 10, gaze: gaze).currentSignals()
        #expect(gaze.count == 0)
    }

    @Test("無操作が閾値を超えたら覗く")
    func peeksOnceIdle() async {
        let gaze = GazeSpy()
        let signals = await engine(idle: 70, gaze: gaze).currentSignals()
        #expect(gaze.count == 1)
        #expect(signals.gaze == .notLooking)
    }

    @Test("間隔を空けずに何度も覗かない")
    func respectsTheInterval() async {
        let gaze = GazeSpy()
        let engine = engine(idle: 70, gaze: gaze)
        let now = Date()

        _ = await engine.currentSignals(now: now)
        _ = await engine.currentSignals(now: now.addingTimeInterval(5))
        _ = await engine.currentSignals(now: now.addingTimeInterval(10))

        #expect(gaze.count == 1)
    }

    @Test("間隔が明ければまた覗く")
    func peeksAgainAfterTheInterval() async {
        let gaze = GazeSpy()
        let engine = engine(idle: 70, gaze: gaze)
        let now = Date()

        _ = await engine.currentSignals(now: now)
        _ = await engine.currentSignals(now: now.addingTimeInterval(31))

        #expect(gaze.count == 2)
    }

    @Test("触り始めたら覚えていた視線を捨てる")
    func forgetsGazeWhenActive() async {
        // 席に戻って作業を再開したのに、さっきの「見ていない」で撮られては困る。
        let gaze = GazeSpy()
        let idle = IdleBox()
        let engine = DetectionEngine(idleMonitor: MacIdleMonitor(probe: { idle.read() }))
        engine.actions = DetectionEngine.Actions(checkGaze: { await gaze.check() })

        idle.set(70)
        _ = await engine.currentSignals()
        #expect(engine.lastGaze == .notLooking)

        idle.set(0)
        let signals = await engine.currentSignals()

        #expect(signals.gaze == .unknown)
        #expect(engine.lastGaze == .unknown)
    }
}

/// 無操作秒数を外から動かす箱。
private final class IdleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func set(_ seconds: TimeInterval) { lock.withLock { value = seconds } }
    func read() -> TimeInterval { lock.withLock { value } }
}
