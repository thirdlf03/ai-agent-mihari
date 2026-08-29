import Foundation
import Testing

@testable import MihariCore

@Suite("Vision ラベル判定(#11)")
struct VisionLabelClassifierTests {

    private func metrics(eyeOpenness: Double?, yaw: Double?) -> FaceLandmarkMetrics {
        FaceLandmarkMetrics(leftEyeOpenness: eyeOpenness, rightEyeOpenness: eyeOpenness, yawRadians: yaw)
    }

    @Test("目を閉じていれば sleeping")
    func closedEyesIsSleeping() {
        let outcome = FaceDetectionOutcome.faceFound(metrics(eyeOpenness: 0.05, yaw: 0.0))
        #expect(VisionLabelClassifier.classify(outcome: outcome) == .sleeping)
    }

    @Test("yaw が大きくてもよそ見とは判定しない")
    func largeYawIsIgnored() {
        // この Vision のリビジョンでは yaw が常に 0.000 しか返らず、実機の映像フレームで
        // まったく機能しなかった。取れていない値でよそ見を断定すると誤判定にしかならない。
        let outcome = FaceDetectionOutcome.faceFound(metrics(eyeOpenness: 0.3, yaw: 0.6))
        #expect(VisionLabelClassifier.classify(outcome: outcome) == .unknown)
    }

    @Test("負の yaw(逆向き)でもよそ見とは判定しない")
    func negativeYawIsIgnored() {
        let outcome = FaceDetectionOutcome.faceFound(metrics(eyeOpenness: 0.3, yaw: -0.6))
        #expect(VisionLabelClassifier.classify(outcome: outcome) == .unknown)
    }

    @Test("yaw がどれだけ大きくても、目が開いていれば見ている扱いのまま")
    func yawNeverAffectsGaze() {
        for yaw in [0.0, 0.4, 1.2, -1.2] {
            let outcome = FaceDetectionOutcome.faceFound(metrics(eyeOpenness: 0.3, yaw: yaw))
            #expect(GazeState.from(outcome: outcome) == .lookingAtScreen, "yaw で判定が変わった: \(yaw)")
        }
    }

    @Test("顔が検出できなければ absent")
    func noFaceIsAbsent() {
        #expect(VisionLabelClassifier.classify(outcome: .noFaceFound) == .absent)
    }

    @Test("目が開いていて正面を向いていれば unknown")
    func normalIsUnknown() {
        let outcome = FaceDetectionOutcome.faceFound(metrics(eyeOpenness: 0.3, yaw: 0.05))
        #expect(VisionLabelClassifier.classify(outcome: outcome) == .unknown)
    }

    @Test("目の開き具合がちょうど閾値なら閉眼扱いにしない(境界)")
    func eyeOpennessAtThresholdIsNotClosed() {
        let threshold = VisionLabelClassifier.defaultClosedEyeOpennessThreshold
        let outcome = FaceDetectionOutcome.faceFound(metrics(eyeOpenness: threshold, yaw: 0.0))
        #expect(VisionLabelClassifier.classify(outcome: outcome) == .unknown)
    }

    @Test("検出処理そのものが失敗したら unknown に倒す(送信は止めない)")
    func detectionFailureFallsBackToUnknown() {
        let outcome = FaceDetectionOutcome.detectionFailed(reason: "テスト用の失敗")
        #expect(VisionLabelClassifier.classify(outcome: outcome) == .unknown)
    }

    @Test("目を閉じていて yaw も大きい場合は sleeping を優先する")
    func closedEyesTakesPriorityOverYaw() {
        let outcome = FaceDetectionOutcome.faceFound(metrics(eyeOpenness: 0.05, yaw: 0.6))
        #expect(VisionLabelClassifier.classify(outcome: outcome) == .sleeping)
    }

    @Test("ランドマークが取れなければ判定材料なしとして unknown")
    func missingLandmarksIsUnknown() {
        let outcome = FaceDetectionOutcome.faceFound(metrics(eyeOpenness: nil, yaw: nil))
        #expect(VisionLabelClassifier.classify(outcome: outcome) == .unknown)
    }

    @Test("閾値を注入できる")
    func thresholdsAreInjectable() {
        let outcome = FaceDetectionOutcome.faceFound(metrics(eyeOpenness: 0.2, yaw: 0.1))
        // 既定の閾値では開眼扱いだが、緩めた(=大きくした)閾値を渡すと閉眼扱いになる。
        #expect(VisionLabelClassifier.classify(outcome: outcome) == .unknown)
        #expect(
            VisionLabelClassifier.classify(outcome: outcome, closedEyeOpennessThreshold: 0.25) == .sleeping
        )
    }
}
