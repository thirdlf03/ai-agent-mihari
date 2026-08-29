import Foundation

/// 判定の閾値。**すべて要調整。** デモしながら詰める前提で、全部外から差し替えられるようにしている。
public struct DetectionThresholds: Equatable, Sendable {

    /// ここを超えたら「疑い」。声をかけ始める。
    public let suspectSeconds: TimeInterval

    /// ここを超えたら「サボり確定」。証拠を取る。
    public let confirmSeconds: TimeInterval

    /// 無操作がこの秒数を超えたら、カメラを開けて視線を見張り始める。
    /// これより手前ではカメラを一切起動しない。手を動かしている間に緑ランプを点けない。
    public let gazeWatchSeconds: TimeInterval

    /// **「画面を見ていない」がこの秒数続いたら確定**にする。
    ///
    /// 判定の主役。単発のフレームで決めると瞬き(0.1〜0.4 秒)で飛ぶが、
    /// 続いた長さで見れば埋もれる。
    public let notLookingDurationSeconds: TimeInterval

    /// 視線の見立てをいつまで信じるか。これより古い結果は使わない。
    /// カメラを止めた直後の値で判定しないための保険。
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
        gazeWatchSeconds: TimeInterval = 60,
        notLookingDurationSeconds: TimeInterval = 15,
        gazeFreshnessSeconds: TimeInterval = 10,
        stampGraceSeconds: TimeInterval = AttendanceGrace.defaultGracePeriod,
        cooldownSeconds: TimeInterval = 180
    ) {
        self.suspectSeconds = suspectSeconds
        self.confirmSeconds = max(suspectSeconds, confirmSeconds)
        self.gazeWatchSeconds = gazeWatchSeconds
        self.notLookingDurationSeconds = notLookingDurationSeconds
        self.gazeFreshnessSeconds = gazeFreshnessSeconds
        self.stampGraceSeconds = stampGraceSeconds
        self.cooldownSeconds = cooldownSeconds
    }

    /// 何か起こりうる最短の無操作秒数。これ未満なら判定を始めるまでもない。
    ///
    /// カメラを開けている間は「見ていない秒数」でも確定しうるので、
    /// 監視を始める秒数も候補に入れる。
    public var minimumIdleSeconds: TimeInterval {
        min(suspectSeconds, gazeWatchSeconds)
    }

    /// 既定値。確定は 5 分。
    public static let `default` = DetectionThresholds()
}
