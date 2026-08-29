import Foundation

/// 判定の閾値。**すべて要調整。** デモしながら詰める前提で、全部外から差し替えられるようにしている。
public struct DetectionThresholds: Equatable, Sendable {

    /// ここを超えたら「疑い」。声をかけ始める。
    public let suspectSeconds: TimeInterval

    /// ここを超えたら「サボり確定」。証拠を取る。
    public let confirmSeconds: TimeInterval

    /// **画面を見ていないと確認できた**場合に確定とする無操作秒数。
    /// 見ていないことが分かっているなら、`confirmSeconds` まで待つ理由がない。
    public let notLookingConfirmSeconds: TimeInterval

    /// 無操作がこの秒数を超えたら、カメラを覗いて視線を確かめ始める。
    /// これより手前ではカメラを一切起動しない。手を動かしている間に緑ランプを点けない。
    public let gazeCheckSeconds: TimeInterval

    /// 視線を確かめる間隔。毎回覗くと緑ランプが点滅し続けるので空ける。
    public let gazeCheckIntervalSeconds: TimeInterval

    /// 視線の見立てをいつまで信じるか。これより古い結果は `.unknown` として扱う。
    public let gazeFreshnessSeconds: TimeInterval

    /// Touch ID の在席スタンプを押した直後の猶予。
    /// 「いま席にいる」と本人が示したのに撮りに行くと、ただの嫌がらせになる。
    public let stampGraceSeconds: TimeInterval

    /// 一度証拠を取ったあと、次に取るまで空ける時間。
    /// これが無いと 1 秒ごとに撮って送り続けることになる。
    public let cooldownSeconds: TimeInterval

    public init(
        suspectSeconds: TimeInterval = 120,
        confirmSeconds: TimeInterval = 300,
        notLookingConfirmSeconds: TimeInterval = 90,
        gazeCheckSeconds: TimeInterval = 60,
        gazeCheckIntervalSeconds: TimeInterval = 30,
        gazeFreshnessSeconds: TimeInterval = 60,
        stampGraceSeconds: TimeInterval = AttendanceGrace.defaultGracePeriod,
        cooldownSeconds: TimeInterval = 180
    ) {
        self.suspectSeconds = suspectSeconds
        self.confirmSeconds = max(suspectSeconds, confirmSeconds)
        self.notLookingConfirmSeconds = notLookingConfirmSeconds
        // 覗き始めるより前に「見ていない」で確定させると、視線が必ず不明のままになる。
        self.gazeCheckSeconds = min(gazeCheckSeconds, notLookingConfirmSeconds)
        self.gazeCheckIntervalSeconds = gazeCheckIntervalSeconds
        self.gazeFreshnessSeconds = gazeFreshnessSeconds
        self.stampGraceSeconds = stampGraceSeconds
        self.cooldownSeconds = cooldownSeconds
    }

    /// 何か起こりうる最短の無操作秒数。これ未満なら判定を始めるまでもない。
    public var minimumIdleSeconds: TimeInterval {
        min(suspectSeconds, notLookingConfirmSeconds)
    }

    /// 既定値。確定は 5 分。
    public static let `default` = DetectionThresholds()
}
