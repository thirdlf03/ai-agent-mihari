import Foundation

/// 顔検出の結果から `SpeechRequest.VisionLabel` を決める判定ロジック。
///
/// Vision フレームワークに一切依存しない。`FaceDetectionOutcome` と閾値さえ渡せば
/// 答えが出るので、実カメラや実 Vision リクエストなしにテストできる。
///
/// **yaw によるよそ見判定は行わない。** この Vision のリビジョンでは
/// `VNFaceObservation.yaw` がほぼ常に 0.000 を返し(真横 90 度でだけ -1.571 が出る程度)、
/// 実機の映像フレームで機能しなかった。よそ見はランドマークから自前で計算した
/// 鼻の左右オフセット(`FaceLandmarkMetrics.noseOffset`)で判定する。
public enum VisionLabelClassifier {

    /// この値を下回ったら目を閉じている(=寝てる)と見なす。
    ///
    /// 実機の映像フレームで測った平常時(目を開けて画面を見ている状態)の分布は
    /// 最小 0.145 / 中央 0.203 / 最大 0.230 だった。元の 0.18 はこの分布の内側にあり、
    /// 19 フレーム中 3 回が「寝ている」に振れていた。正常値の下限からさらに余裕を取る。
    public static let defaultClosedEyeOpennessThreshold = 0.12

    /// 鼻の左右オフセットの絶対値がこの値を超えたら、横を向いている(よそ見)と見なす。
    ///
    /// 視線キャリブレーション(MIHARI_SELFTEST_GAZE=1)の実測では、画面を見ている 72 フレームで
    /// |noseOffset| は最大 0.082、横を向いた 24 フレームでは中央値 0.738 だった。
    /// 正常値の最大からおよそ 3 倍のマージンを取ってこの値に置く。
    public static let defaultLookingAwayNoseOffsetThreshold = 0.25

    /// 顔検出の結果全体からラベルを決める。
    ///
    /// 優先順位: 顔なし(不在) > 目を閉じている(寝てる) > 横を向いている(よそ見) > 不明。
    public static func classify(
        outcome: FaceDetectionOutcome,
        closedEyeOpennessThreshold: Double = defaultClosedEyeOpennessThreshold,
        lookingAwayNoseOffsetThreshold: Double = defaultLookingAwayNoseOffsetThreshold
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
                lookingAwayNoseOffsetThreshold: lookingAwayNoseOffsetThreshold
            )
        }
    }

    /// 顔は見つかっている前提で、指標だけから判定する。
    public static func classify(
        metrics: FaceLandmarkMetrics,
        closedEyeOpennessThreshold: Double = defaultClosedEyeOpennessThreshold,
        lookingAwayNoseOffsetThreshold: Double = defaultLookingAwayNoseOffsetThreshold
    ) -> SpeechRequest.VisionLabel {
        if let openness = metrics.averageEyeOpenness, openness < closedEyeOpennessThreshold {
            return .sleeping
        }
        if let noseOffset = metrics.noseOffset, abs(noseOffset) > lookingAwayNoseOffsetThreshold {
            return .lookingAway
        }
        return .unknown
    }
}
