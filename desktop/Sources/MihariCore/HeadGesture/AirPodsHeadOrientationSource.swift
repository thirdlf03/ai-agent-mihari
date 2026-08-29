import CoreMotion
import Foundation
import os

/// `CMHeadphoneMotionManager` を使う本物の実装。
///
/// macOS 14.0+ の API で、SaboriLab の21モジュールでは唯一未検証だった。疎通確認では、
/// AirPods が Bluetooth 接続されていない状態で `isDeviceMotionAvailable` が `true` を返す
/// (対応機種かどうかだけを見ており、接続状態そのものは見ていない)ことと、
/// `startDeviceMotionUpdates` を呼んだ瞬間に認可プロンプトが出て `authorizationStatus()` が
/// `authorized` に変わることを確認した。実際に接続した AirPods から `CMDeviceMotion` が
/// 流れてくるかは、AirPods が手元になく未確認(詳細は `desktop/README.md`)。
///
/// 認可要求には専用の API がなく、`startDeviceMotionUpdates` を呼んだ瞬間にプロンプトが出る。
/// これは `PermissionRequester.requestMotion` と同じ挙動で、権限の状態そのものは
/// `PermissionChecker.check(.motion)` を再利用して読む。
public final class AirPodsHeadOrientationSource: HeadOrientationSource, @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "head-gesture")

    /// ラジアンから度への変換係数。`CMAttitude` はラジアンで値を返すため、判定ロジック側の
    /// 都合(度のほうが閾値を読みやすい)に合わせてここで変換する。
    private static let radiansToDegrees = 180.0 / Double.pi

    private let manager = CMHeadphoneMotionManager()
    private let queue: OperationQueue

    public init() {
        let queue = OperationQueue()
        queue.name = "com.thirdlf03.mihari.head-gesture"
        queue.maxConcurrentOperationCount = 1
        self.queue = queue
    }

    public func availability() -> HeadGestureAvailability {
        guard manager.isDeviceMotionAvailable else {
            return .unavailable(reason: "AirPods が接続されていないか、対応していない機種")
        }

        // 権限の状態は既存の PermissionChecker/PermissionStateMapper をそのまま使う。
        // notDetermined でも `startDeviceMotionUpdates` を呼べばプロンプトが出るため、ここでは弾かない。
        let state = PermissionChecker.check(.motion)
        if state.grant == .denied {
            return .unavailable(reason: "モーションの権限が許可されていない(\(state.detail))")
        }
        return .available
    }

    public func updates() -> AsyncStream<HeadOrientationSample> {
        AsyncStream { continuation in
            manager.startDeviceMotionUpdates(to: queue) { motion, error in
                if let error {
                    Self.logger.error("device motion error: \(error.localizedDescription, privacy: .public)")
                    return
                }
                guard let motion else { return }
                continuation.yield(
                    HeadOrientationSample(
                        timestamp: motion.timestamp,
                        pitchDegrees: motion.attitude.pitch * Self.radiansToDegrees,
                        yawDegrees: motion.attitude.yaw * Self.radiansToDegrees
                    )
                )
            }
            // ストリームの消費側がキャンセルされる(タイムアウトや画面の破棄)と、AsyncStream の
            // next() がキャンセルを検知してここを呼ぶ。バッテリーを消費し続けないよう必ず止める。
            continuation.onTermination = { [weak self] _ in
                self?.manager.stopDeviceMotionUpdates()
            }
        }
    }
}
