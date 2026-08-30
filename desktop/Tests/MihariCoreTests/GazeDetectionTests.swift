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

// 視線は判定のトリガーから外した(監視ループ v2)。ここに残しているのは、
// 見立てそのもの(`GazeState` / `GazeObservation`)と `GazeMonitor` の後始末だけ。

@Suite("GazeMonitor の停止待ち")
struct GazeMonitorStopTests {

    @Test("開始していないモニタでも stopAndWait はハングせず戻る")
    func stopAndWaitReturnsWithoutStart() async {
        let monitor = GazeMonitor()
        await monitor.stopAndWait()
        #expect(!monitor.isRunning)
    }

    @Test("start 直後に stopAndWait しても戻る(キューに積まれた処理を追い越さない)")
    func stopAndWaitAfterStartReturns() async {
        let monitor = GazeMonitor()
        monitor.start()
        await monitor.stopAndWait()
        #expect(!monitor.isRunning)
    }
}
