import Foundation

/// 首振りジェスチャ判定の閾値。すべて名前付き定数にし、`HeadGestureRecognizer` に注入できるようにする。
///
/// AirPods の実データでは未検証(#18 時点)のため、`default` は日常の首の動きで誤反応しない方向に
/// 倒した見積もり値。`HeadGestureView` で生の pitch/yaw を出しているのは、実機でこれを調整するため。
public struct HeadGestureThresholds: Sendable, Equatable {

    /// この振れ幅(度)未満の動きは「日常の首の動き」とみなして無視する。
    /// 画面を見るときの視線移動は経験的に 10 度未満に収まることが多いため、
    /// 明確な首振りだけを拾えるよう余裕を持って大きめにしている。
    public let minAmplitudeDegrees: Double

    /// 往復(方向転換)がこの回数以上ないと、うなずき/首振りとして認めない。
    /// 1往復(2回反転)未満は「一度だけ下を見て戻す」動作と区別できないため、最低2回を要求する。
    public let minReversalCount: Int

    /// この秒数より前のサンプルは判定に使わない。この窓の中で振れ幅と往復回数を数える。
    /// 人が意図してうなずく/首を振るときの1往復はおよそ0.3〜0.6秒なので、2往復分の余裕を見て設定する。
    public let timeWindowSeconds: TimeInterval

    /// 反転を数えるときに無視する変化量(度)。センサーノイズや首の微振動を
    /// 反転として誤カウントしないための下限。
    public let noiseFloorDegrees: Double

    /// 主軸(pitch または yaw)に対して、もう一方の軸の振れ幅がこの比率を超えたら判定を保留する。
    /// 首を斜めに振ったときに、うなずきと首振りを取り違えないための安全弁。
    public let maxCrossAxisRatio: Double

    public init(
        minAmplitudeDegrees: Double,
        minReversalCount: Int,
        timeWindowSeconds: TimeInterval,
        noiseFloorDegrees: Double,
        maxCrossAxisRatio: Double
    ) {
        self.minAmplitudeDegrees = minAmplitudeDegrees
        self.minReversalCount = minReversalCount
        self.timeWindowSeconds = timeWindowSeconds
        self.noiseFloorDegrees = noiseFloorDegrees
        self.maxCrossAxisRatio = maxCrossAxisRatio
    }

    /// 実機未検証のため、まずは誤反応を避ける方向に倒した既定値。根拠は `desktop/README.md` を参照。
    public static let `default` = HeadGestureThresholds(
        minAmplitudeDegrees: 12.0,
        minReversalCount: 2,
        timeWindowSeconds: 1.6,
        noiseFloorDegrees: 1.5,
        maxCrossAxisRatio: 0.6
    )
}
