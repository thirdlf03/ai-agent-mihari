import Foundation

/// 顔検出の結果から `SpeechRequest.VisionLabel` を決める判定ロジック。
///
/// Vision フレームワークに一切依存しない。`FaceDetectionOutcome` と閾値さえ渡せば
/// 答えが出るので、実カメラや実 Vision リクエストなしにテストできる。
///
/// **よそ見(yaw)判定は行わない。** この Vision のリビジョンでは
/// `VNFaceObservation.yaw` が常に 0.000 を返し、実機の映像フレームでまったく
/// 機能しなかった(顔の向きが取れていない)。取れていない値でよそ見を断定すると
/// 誤判定にしかならないため、いまは「顔の有無」と「目の開き具合」だけで見る。
public enum VisionLabelClassifier {

    /// この値を下回ったら目を閉じている(=寝てる)と見なす。
    ///
    /// 実機の映像フレームで測った平常時(目を開けて画面を見ている状態)の分布は
    /// 最小 0.145 / 中央 0.203 / 最大 0.230 だった。元の 0.18 はこの分布の内側にあり、
    /// 19 フレーム中 3 回が「寝ている」に振れていた。正常値の下限からさらに余裕を取る。
    public static let defaultClosedEyeOpennessThreshold = 0.12

    /// 顔検出の結果全体からラベルを決める。
    ///
    /// 優先順位: 顔なし(不在) > 目を閉じている(寝てる) > どれでもなければ不明。
    public static func classify(
        outcome: FaceDetectionOutcome,
        closedEyeOpennessThreshold: Double = defaultClosedEyeOpennessThreshold
    ) -> SpeechRequest.VisionLabel {
        switch outcome {
        case .detectionFailed:
            // 顔が写っていないのか判定に失敗しただけなのか区別できないので、断定しない。
            return .unknown
        case .noFaceFound:
            return .absent
        case .faceFound(let metrics):
            return classify(metrics: metrics, closedEyeOpennessThreshold: closedEyeOpennessThreshold)
        }
    }

    /// 顔は見つかっている前提で、指標だけから判定する。
    public static func classify(
        metrics: FaceLandmarkMetrics,
        closedEyeOpennessThreshold: Double = defaultClosedEyeOpennessThreshold
    ) -> SpeechRequest.VisionLabel {
        if let openness = metrics.averageEyeOpenness, openness < closedEyeOpennessThreshold {
            return .sleeping
        }
        return .unknown
    }
}
