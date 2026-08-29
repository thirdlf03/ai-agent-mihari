import Foundation

/// 連続監視から出てくる、いまの視線の状況。
public struct GazeObservation: Equatable, Sendable {

    /// 直近のフレームでの見立て。
    public let state: GazeState

    /// 「見ていない」が続いている秒数。見ている / 不明なら 0。
    ///
    /// **判定の主役はこの秒数。** 1 フレームだけで決めると瞬きで飛ぶので、
    /// 続いた長さで判断する。
    public let notLookingSeconds: TimeInterval

    /// 直近フレームの目の開き具合。閾値を詰めるために画面へ出す。
    public let eyeOpenness: Double?

    /// 直近フレームの yaw(ラジアン)。
    public let yawRadians: Double?

    /// 直近フレームの鼻の左右オフセット(顔向きプロキシ)。しきい値調整のための実測用。
    public let noseOffset: Double?

    /// 最後にフレームを見た時刻。古すぎる結果を信じないために使う。
    public let updatedAt: Date?

    public init(
        state: GazeState = .unknown,
        notLookingSeconds: TimeInterval = 0,
        eyeOpenness: Double? = nil,
        yawRadians: Double? = nil,
        noseOffset: Double? = nil,
        updatedAt: Date? = nil
    ) {
        self.state = state
        self.notLookingSeconds = notLookingSeconds
        self.eyeOpenness = eyeOpenness
        self.yawRadians = yawRadians
        self.noseOffset = noseOffset
        self.updatedAt = updatedAt
    }

    /// まだ何も見ていない状態。
    public static let none = GazeObservation()

    /// 結果が新しいか。カメラが止まったあとの古い値で判定しないための確認。
    public func isFresh(now: Date, within seconds: TimeInterval) -> Bool {
        guard let updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) <= seconds
    }

    /// 画面に出す一言。
    public var summary: String {
        switch state {
        case .notLooking:
            return "画面を見ていない（\(Int(notLookingSeconds))秒）"
        case .lookingAtScreen, .unknown:
            return state.label
        }
    }
}
