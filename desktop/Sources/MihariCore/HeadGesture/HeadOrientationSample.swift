import Foundation

/// ある瞬間の頭の向き。`CMDeviceMotion` の `attitude` から作る、CoreMotion に依存しない値。
///
/// 判定ロジック(`HeadGestureRecognizer`)はこの型だけを見て動くため、CoreMotion なしでもテストできる。
public struct HeadOrientationSample: Sendable, Equatable {

    /// サンプルが取れた時刻(秒)。単調増加であることを前提にする。`CMDeviceMotion.timestamp` を想定。
    public let timestamp: TimeInterval

    /// うなずき方向の角度(度)。上下どちらを正にするかは問わない。相対的な変化だけを見て判定する。
    public let pitchDegrees: Double

    /// 首を横に振る方向の角度(度)。
    public let yawDegrees: Double

    public init(timestamp: TimeInterval, pitchDegrees: Double, yawDegrees: Double) {
        self.timestamp = timestamp
        self.pitchDegrees = pitchDegrees
        self.yawDegrees = yawDegrees
    }
}
