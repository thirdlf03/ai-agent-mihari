import Foundation

/// 顔検出の結果から `SpeechRequest.VisionLabel` を決める判定ロジック。
///
/// Vision フレームワークに一切依存しない。`FaceDetectionOutcome` と閾値さえ渡せば
/// 答えが出るので、実カメラや実 Vision リクエストなしにテストできる。
public enum VisionLabelClassifier {

    /// この値を下回ったら目を閉じている(=寝てる)と見なす。
    /// SaboriLab モジュール 11(`FaceAnalyzer.closedEyeRatioThreshold`)での検証値を引き継ぐ。
    public static let defaultClosedEyeOpennessThreshold = 0.18

    /// この値(ラジアン。約 20 度)の絶対値を上回ったらよそ見と見なす。
    /// SaboriLab モジュール 11(`FaceAnalyzer.lookingAwayYawThreshold`)での検証値を引き継ぐ。
    public static let defaultLookingAwayYawRadiansThreshold = 0.35

    /// 顔検出の結果全体からラベルを決める。
    ///
    /// 優先順位は Issue #11 の記述順のとおり:
    /// 顔なし(不在) > 目を閉じている(寝てる) > よそ見 > どれでもなければ不明。
    public static func classify(
        outcome: FaceDetectionOutcome,
        closedEyeOpennessThreshold: Double = defaultClosedEyeOpennessThreshold,
        lookingAwayYawRadiansThreshold: Double = defaultLookingAwayYawRadiansThreshold
    ) -> SpeechRequest.VisionLabel {
        switch outcome {
        case .detectionFailed:
            // 顔が写っていないのか判定に失敗しただけなのか区別できないので、断定しない。
            return .unknown
        case .noFaceFound:
            return .absent
        case .faceFound(let metrics):
            return classify(
                metrics: metrics,
                closedEyeOpennessThreshold: closedEyeOpennessThreshold,
                lookingAwayYawRadiansThreshold: lookingAwayYawRadiansThreshold
            )
        }
    }

    /// 顔は見つかっている前提で、指標だけから判定する。
    public static func classify(
        metrics: FaceLandmarkMetrics,
        closedEyeOpennessThreshold: Double = defaultClosedEyeOpennessThreshold,
        lookingAwayYawRadiansThreshold: Double = defaultLookingAwayYawRadiansThreshold
    ) -> SpeechRequest.VisionLabel {
        if let openness = metrics.averageEyeOpenness, openness < closedEyeOpennessThreshold {
            return .sleeping
        }
        if let yaw = metrics.yawRadians, abs(yaw) > lookingAwayYawRadiansThreshold {
            return .lookingAway
        }
        return .unknown
    }
}
