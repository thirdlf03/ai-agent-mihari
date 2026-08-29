import Foundation

/// pitch / yaw の時系列から「うなずき = はい」「首振り = いいえ」を判定する。
///
/// **CoreMotion には依存しない。** `HeadOrientationSample` の時系列を渡すだけで判定できるため、
/// 実機や AirPods がなくても単体テストできる。`CMHeadphoneMotionManager` を使う側
/// (`AirPodsHeadOrientationSource`)から角度だけを取り出して渡す想定。
public struct HeadGestureRecognizer {

    /// 1サンプル取り込むごとに返る、その時点までの判定。
    public enum Decision: Sendable, Equatable {
        /// うなずきと判定した。
        case yes
        /// 首振りと判定した。
        case no
        /// まだどちらとも判定できていない。
        case none
    }

    private let thresholds: HeadGestureThresholds
    private var buffer: [HeadOrientationSample] = []

    public init(thresholds: HeadGestureThresholds = .default) {
        self.thresholds = thresholds
    }

    /// サンプルを1つ取り込み、時間窓に収まるサンプルだけで判定し直す。
    ///
    /// 時間窓から外れた古いサンプルはここで捨てるため、離れた時刻に起きた別々の往復が
    /// まとめて数えられることはない。
    @discardableResult
    public mutating func ingest(_ sample: HeadOrientationSample) -> Decision {
        buffer.append(sample)
        trim(before: sample.timestamp - thresholds.timeWindowSeconds)
        return evaluate()
    }

    private mutating func trim(before earliest: TimeInterval) {
        buffer.removeAll { $0.timestamp < earliest }
    }

    private func evaluate() -> Decision {
        // 反転の有無を判定するには、最低でも3点(始点・折り返し・終点)が要る。
        guard buffer.count >= 3 else { return .none }

        let pitch = analyze(buffer.map(\.pitchDegrees))
        let yaw = analyze(buffer.map(\.yawDegrees))

        let pitchIsGesture = isGesture(pitch)
        let yawIsGesture = isGesture(yaw)

        // 両軸が同時に閾値を満たす場合は、斜めの動きとして判定を保留する。
        guard pitchIsGesture != yawIsGesture else { return .none }

        if pitchIsGesture, yaw.amplitudeDegrees <= pitch.amplitudeDegrees * thresholds.maxCrossAxisRatio {
            return .yes
        }
        if yawIsGesture, pitch.amplitudeDegrees <= yaw.amplitudeDegrees * thresholds.maxCrossAxisRatio {
            return .no
        }
        return .none
    }

    private func isGesture(_ analysis: AxisAnalysis) -> Bool {
        analysis.amplitudeDegrees >= thresholds.minAmplitudeDegrees
            && analysis.reversalCount >= thresholds.minReversalCount
    }

    private struct AxisAnalysis {
        let amplitudeDegrees: Double
        let reversalCount: Int
    }

    /// 振れ幅(最大-最小)と、ノイズを除いた方向転換の回数を数える。
    ///
    /// ノイズフロア未満の変化は方向判定に使わず、直前の有意な値を基準に次の変化を見る。
    /// これにより、センサーの微振動が反転として誤カウントされるのを防ぐ。
    private func analyze(_ values: [Double]) -> AxisAnalysis {
        guard let first = values.first, let maxValue = values.max(), let minValue = values.min() else {
            return AxisAnalysis(amplitudeDegrees: 0, reversalCount: 0)
        }

        var reversalCount = 0
        var direction = 0
        var previous = first

        for value in values.dropFirst() {
            let delta = value - previous
            guard abs(delta) >= thresholds.noiseFloorDegrees else { continue }

            let newDirection = delta > 0 ? 1 : -1
            if direction != 0 && newDirection != direction {
                reversalCount += 1
            }
            direction = newDirection
            previous = value
        }

        return AxisAnalysis(amplitudeDegrees: maxValue - minValue, reversalCount: reversalCount)
    }
}
