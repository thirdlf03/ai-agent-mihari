import Foundation

/// 1 枚の画像に対する顔検出の結果。
///
/// 「顔が 0 件だった」ことと「検出処理そのものが例外を投げた」ことを区別する。
/// 前者は Issue #11 の受け入れ条件どおり `.absent` に倒し、後者は原因不明のまま
/// `.unknown` に倒す(ラベル付けは付加価値であって、これが原因で撮影や送信を止めない)。
public enum FaceDetectionOutcome: Sendable, Equatable {
    /// Vision の処理自体が例外を投げた。`reason` はログ・UI 表示用。
    case detectionFailed(reason: String)
    /// 検出処理は成功したが、顔が 1 件も見つからなかった。
    case noFaceFound
    /// 顔が見つかった。複数人写っていても、最も信頼度の高い 1 件の指標だけを持つ
    /// (このアプリの用途は本人 1 人の在席確認であり、他人を巻き込む必要がない)。
    case faceFound(FaceLandmarkMetrics)
}
