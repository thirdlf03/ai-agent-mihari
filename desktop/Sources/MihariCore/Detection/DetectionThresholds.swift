import Foundation

/// 判定の閾値。**すべて要調整。** デモしながら詰める前提で、全部外から差し替えられるようにしている。
public struct DetectionThresholds: Equatable, Sendable {

    /// ここを超えたら「疑い」。声をかけ始める。
    public let suspectSeconds: TimeInterval

    /// ここを超えたら「サボり確定」。証拠を取る。
    public let confirmSeconds: TimeInterval

    /// Touch ID の在席スタンプを押した直後の猶予。
    /// 「いま席にいる」と本人が示したのに撮りに行くと、ただの嫌がらせになる。
    public let stampGraceSeconds: TimeInterval

    /// 一度証拠を取ったあと、次に取るまで空ける時間。
    /// これが無いと 1 秒ごとに撮って送り続けることになる。
    public let cooldownSeconds: TimeInterval

    public init(
        suspectSeconds: TimeInterval = 120,
        confirmSeconds: TimeInterval = 300,
        stampGraceSeconds: TimeInterval = AttendanceGrace.defaultGracePeriod,
        cooldownSeconds: TimeInterval = 180
    ) {
        self.suspectSeconds = suspectSeconds
        self.confirmSeconds = max(suspectSeconds, confirmSeconds)
        self.stampGraceSeconds = stampGraceSeconds
        self.cooldownSeconds = cooldownSeconds
    }

    /// 既定値。確定は 5 分。
    public static let `default` = DetectionThresholds()
}
