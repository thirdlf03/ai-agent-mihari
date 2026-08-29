import Foundation

/// 1 枚の画像から取れた、顔 1 件分の判定用の指標。
///
/// Vision の生の観測値そのものではなく、判定器(`VisionLabelClassifier`)が必要とする値
/// だけに絞ってある。UI(`VisionView`)で「算出した指標の生の値」として出すのもこの型。
public struct FaceLandmarkMetrics: Sendable, Equatable {

    /// 左目の開き具合(縦幅 / 横幅)。ランドマークが取れなければ `nil`。
    public let leftEyeOpenness: Double?
    /// 右目の開き具合。
    public let rightEyeOpenness: Double?
    /// 顔の左右の向き(ラジアン)。0 が正面、絶対値が大きいほど横を向いている。
    /// `VNFaceObservation.yaw` は検出リビジョンによっては `nil` になることがある。
    public let yawRadians: Double?

    public init(leftEyeOpenness: Double?, rightEyeOpenness: Double?, yawRadians: Double?) {
        self.leftEyeOpenness = leftEyeOpenness
        self.rightEyeOpenness = rightEyeOpenness
        self.yawRadians = yawRadians
    }

    /// 左右の目の開き具合の平均。片方しか取れなければそちらだけを使う。
    public var averageEyeOpenness: Double? {
        FaceLandmarkGeometry.averageEyeOpenness(left: leftEyeOpenness, right: rightEyeOpenness)
    }

    /// yaw を度数に変換した値。UI 表示用(ラジアンのままだと直感的でないため)。
    public var yawDegrees: Double? {
        yawRadians.map { $0 * 180 / .pi }
    }
}
