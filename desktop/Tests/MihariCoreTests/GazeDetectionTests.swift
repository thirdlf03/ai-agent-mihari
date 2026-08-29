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

    @Test("よそ見は判定しない（yaw が取れないため）")
    func yawIsNotUsed() {
        // 実機の映像フレームで yaw は常に 0.000 だった。取れていない値で
        // よそ見を断定すると、作業中の人を撮ることになる。
        #expect(GazeState.from(outcome: .faceFound(metrics(openness: 0.30, yaw: 0.9))) == .lookingAtScreen)
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

    @Test("実機で測った通常時の目の開きが「寝ている」にならない")
    func typicalOpenEyesAreNotSleeping() {
        // 実機で測った平常時の値は 0.193〜0.239 だった。ここが閾値に近すぎると、
        // わずかに細めただけで寝ていると誤判定して撮られてしまう。
        for openness in [0.193, 0.203, 0.216, 0.239] {
            #expect(
                GazeState.from(outcome: .faceFound(metrics(openness: openness, yaw: 0.0)))
                    == .lookingAtScreen,
                "平常時の値を寝ていると誤判定した: \(openness)"
            )
        }
    }
}

@Suite("見ていない時間の積み上げ")
struct GazeObservationTests {

    @Test("何も見ていない状態は新しくない")
    func noneIsNeverFresh() {
        #expect(GazeObservation.none.isFresh(now: Date(), within: 10) == false)
    }

    @Test("直近の結果は新しい")
    func recentIsFresh() {
        let now = Date()
        let observation = GazeObservation(state: .notLooking, updatedAt: now.addingTimeInterval(-3))
        #expect(observation.isFresh(now: now, within: 10))
    }

    @Test("古い結果は使わない")
    func staleIsNotFresh() {
        // カメラを止めた直後の値で判定しないための保険。
        let now = Date()
        let observation = GazeObservation(state: .notLooking, updatedAt: now.addingTimeInterval(-30))
        #expect(observation.isFresh(now: now, within: 10) == false)
    }

    @Test("見ていない状態は続いた秒数つきで表示する")
    func summaryShowsDuration() {
        let observation = GazeObservation(state: .notLooking, notLookingSeconds: 18)
        #expect(observation.summary.contains("18"))
    }
}

@Suite("画面を見ていないときの判定")
struct NotLookingJudgeTests {

    private let judge = DetectionJudge(thresholds: .production)

    private func signals(idle: TimeInterval, notLooking: TimeInterval) -> DetectionSignals {
        DetectionSignals(
            macIdleSeconds: idle,
            gaze: GazeObservation(
                state: notLooking > 0 ? .notLooking : .lookingAtScreen,
                notLookingSeconds: notLooking,
                updatedAt: Date()
            )
        )
    }

    @Test("見ていない状態が続けば、無操作 5 分を待たずに確定する")
    func sustainedNotLookingConfirmsEarly() {
        let decision = judge.decide(signals(idle: 70, notLooking: 20))
        #expect(decision.state == .confirmed)
        #expect(decision.evidence == .macCamera)
    }

    @Test("短い間だけ見ていなくても確定しない")
    func briefNotLookingIsIgnored() {
        // 瞬きや一瞬よそを向いただけで撮られては困る。
        #expect(judge.decide(signals(idle: 70, notLooking: 3)).state == .normal)
    }

    @Test("継続時間の境界は 15 秒ちょうどから")
    func durationBoundary() {
        #expect(judge.decide(signals(idle: 70, notLooking: 14)).state == .normal)
        #expect(judge.decide(signals(idle: 70, notLooking: 15)).state == .confirmed)
    }

    @Test("どちらの条件で引っかかったかが根拠に残る")
    func reasonNamesTheCause() {
        let byGaze = judge.decide(signals(idle: 70, notLooking: 20)).reason
        #expect(byGaze.contains("見ていない"))
        #expect(!judge.decide(signals(idle: 400, notLooking: 0)).reason.contains("見ていない"))
    }

    @Test("画面を見ていても無操作が続けば、これまで通り時間で確定する")
    func lookingStillConfirmsOnTime() {
        #expect(judge.decide(signals(idle: 400, notLooking: 0)).state == .confirmed)
    }

    @Test("カメラが使えていなければ早期確定しない")
    func withoutCameraNoEarlyConfirm() {
        // 視線が取れないだけで撮られては困る。
        let blind = DetectionSignals(macIdleSeconds: 100, gaze: .none)
        #expect(judge.decide(blind).state == .normal)
    }

    @Test("見ていなくても在席スタンプ直後なら見逃す")
    func stampStillWins() {
        let signals = DetectionSignals(
            macIdleSeconds: 200,
            gaze: GazeObservation(state: .notLooking, notLookingSeconds: 60, updatedAt: Date()),
            secondsSinceStamp: 30
        )
        #expect(judge.decide(signals).state == .normal)
    }
}

@Suite("カメラを開ける条件")
@MainActor
struct GazeMonitoringTests {

    /// 実際のカメラを開けずに、開け閉めだけを記録する。
    private final class MonitorSpy: GazeMonitor {
        private let spyLock = NSLock()
        private var _running = false
        private var _starts = 0
        private var _stops = 0
        private var _observation = GazeObservation.none

        override var isRunning: Bool { spyLock.withLock { _running } }
        override var observation: GazeObservation { spyLock.withLock { _observation } }
        var starts: Int { spyLock.withLock { _starts } }
        var stops: Int { spyLock.withLock { _stops } }

        func setObservation(_ value: GazeObservation) { spyLock.withLock { _observation = value } }
        override func start() {
            spyLock.withLock {
                _running = true
                _starts += 1
            }
        }
        override func stop() {
            spyLock.withLock {
                _running = false
                _stops += 1
            }
        }
    }

    private func engine(idle: TimeInterval, monitor: MonitorSpy) -> DetectionEngine {
        let engine = DetectionEngine(idleMonitor: MacIdleMonitor(probe: { idle }), gazeMonitor: monitor)
        engine.thresholds = .production
        return engine
    }

    @Test("手を動かしている間はカメラを開けない")
    func neverOpensWhileActive() async {
        // 緑ランプが点きっぱなしになると、ただの監視カメラになってしまう。
        let monitor = MonitorSpy()
        _ = await engine(idle: 10, monitor: monitor).currentSignals()
        #expect(monitor.starts == 0)
    }

    @Test("無操作が閾値を超えたらカメラを開ける")
    func opensOnceIdle() async {
        let monitor = MonitorSpy()
        _ = await engine(idle: 70, monitor: monitor).currentSignals()
        #expect(monitor.starts == 1)
    }

    @Test("すでに開いていれば開き直さない")
    func doesNotReopen() async {
        let monitor = MonitorSpy()
        let engine = engine(idle: 70, monitor: monitor)
        _ = await engine.currentSignals()
        _ = await engine.currentSignals()
        #expect(monitor.starts == 1)
    }

    @Test("触り始めたらカメラを閉じて、覚えていた結果も捨てる")
    func closesWhenActive() async {
        // 席に戻って作業を再開したのに、さっきの「見ていない」で撮られては困る。
        let monitor = MonitorSpy()
        let idle = IdleBox()
        let engine = DetectionEngine(
            idleMonitor: MacIdleMonitor(probe: { idle.read() }),
            gazeMonitor: monitor
        )
        engine.thresholds = .production

        idle.set(70)
        monitor.setObservation(GazeObservation(state: .notLooking, notLookingSeconds: 40, updatedAt: Date()))
        _ = await engine.currentSignals()
        #expect(engine.gaze.state == .notLooking)

        idle.set(0)
        let signals = await engine.currentSignals()

        #expect(monitor.stops == 1)
        #expect(signals.gaze == .none)
        #expect(engine.gaze == .none)
    }

    @Test("古い観測結果は判定に使わない")
    func staleObservationIsDropped() async {
        let monitor = MonitorSpy()
        monitor.setObservation(
            GazeObservation(state: .notLooking, notLookingSeconds: 60, updatedAt: Date().addingTimeInterval(-120))
        )
        let signals = await engine(idle: 70, monitor: monitor).currentSignals()
        #expect(signals.gaze == .none)
    }

    @Test("監視を止めるとカメラも閉じる")
    func stopClosesTheCamera() async {
        let monitor = MonitorSpy()
        let engine = engine(idle: 70, monitor: monitor)
        _ = await engine.currentSignals()

        engine.stop()

        #expect(monitor.stops >= 1)
        #expect(engine.gaze == .none)
    }
}

/// 無操作秒数を外から動かす箱。
private final class IdleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func set(_ seconds: TimeInterval) { lock.withLock { value = seconds } }
    func read() -> TimeInterval { lock.withLock { value } }
}
