import Foundation

/// 画面を見ているか。
///
/// カメラを覗いて顔が取れたかどうかから決める。**常時カメラを回さない**ため、
/// 無操作がある程度続いてから、間隔を空けて確かめる。手を動かしている間は一切起動しない。
public enum GazeState: String, Equatable, Sendable, CaseIterable {
    /// 顔が正面を向いていて目も開いている。画面を見ている。
    case lookingAtScreen
    /// 寝ている・よそ見・そもそも人がいない。画面を見ていない。
    case notLooking
    /// カメラが使えない、検出に失敗した、まだ覗いていない。**見ていないと決めつけない。**
    case unknown

    public var label: String {
        switch self {
        case .lookingAtScreen: return "画面を見ている"
        case .notLooking: return "画面を見ていない"
        case .unknown: return "不明"
        }
    }

    /// Vision の見立てから視線を決める。
    ///
    /// 「顔は取れたが目は開いている」を `lookingAtScreen` として拾うため、
    /// `SpeechRequest.VisionLabel` ではなく検出結果そのものから作る。
    /// ラベル側は `unknown` が「目が開いている」と「判定できなかった」の
    /// 両方を指してしまい、この 2 つを混ぜると見ていないのに見ていると誤るおそれがある。
    ///
    /// **よそ見は見ない。** yaw が取れないため、いまは
    /// 「顔が写っているか」と「目が開いているか」だけで決めている。
    public static func from(outcome: FaceDetectionOutcome) -> GazeState {
        switch outcome {
        case .detectionFailed:
            return .unknown
        case .noFaceFound:
            // 誰も写っていない = 席にいない。見ていないと判断してよい。
            return .notLooking
        case .faceFound(let metrics):
            switch VisionLabelClassifier.classify(metrics: metrics) {
            case .sleeping, .absent:
                return .notLooking
            case .lookingAway:
                // いまの分類器はこれを返さないが、将来よそ見を復活させたときに
                // ここで拾えるよう残しておく。
                return .notLooking
            case .unknown:
                return .lookingAtScreen
            }
        }
    }
}
