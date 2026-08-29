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

    /// 「休憩中?」に はい と答えたとき、見張りを止めておく時間。
    /// この間はカメラも開かないし、撮らない・送らない・喋らない。
    public let breakDurationSeconds: TimeInterval

    /// 「休憩中?」の返事を待つ時間。これを過ぎたら無反応として問いかけを閉じ、監視を続ける。
    public let promptTimeoutSeconds: TimeInterval

    public init(
        suspectSeconds: TimeInterval = 12,
        confirmSeconds: TimeInterval = 30,
        gazeWatchSeconds: TimeInterval = 6,
        notLookingDurationSeconds: TimeInterval = 15,
        gazeFreshnessSeconds: TimeInterval = 10,
        stampGraceSeconds: TimeInterval = AttendanceGrace.defaultGracePeriod,
        cooldownSeconds: TimeInterval = 180,
        breakDurationSeconds: TimeInterval = 900,
        promptTimeoutSeconds: TimeInterval = 20
    ) {
        self.suspectSeconds = suspectSeconds
        self.confirmSeconds = max(suspectSeconds, confirmSeconds)
        self.gazeWatchSeconds = gazeWatchSeconds
        self.notLookingDurationSeconds = notLookingDurationSeconds
        self.gazeFreshnessSeconds = gazeFreshnessSeconds
        self.stampGraceSeconds = stampGraceSeconds
        self.cooldownSeconds = cooldownSeconds
        self.breakDurationSeconds = breakDurationSeconds
        self.promptTimeoutSeconds = promptTimeoutSeconds
    }

    /// 何か起こりうる最短の無操作秒数。これ未満なら判定を始めるまでもない。
    ///
    /// カメラを開けている間は「見ていない秒数」でも確定しうるので、
    /// 監視を始める秒数も候補に入れる。
    public var minimumIdleSeconds: TimeInterval {
        min(suspectSeconds, gazeWatchSeconds)
    }

    /// 既定値。**一時的に** 疑い 12 秒 / 確定 30 秒 / カメラ 6 秒まで縮めている。本来は 120 / 300 / 60。
    ///
    /// `MIHARI_FAST_THRESHOLDS=1` を付けて起動すると、動作確認用に全部を秒単位まで縮める。
    /// 5 分待たずに一連の流れが通るかを見られる。デモの調整にも使う。
    public static var `default`: DetectionThresholds {
        guard ProcessInfo.processInfo.environment["MIHARI_FAST_THRESHOLDS"] == "1" else {
            return DetectionThresholds()
        }
        return DetectionThresholds(
            suspectSeconds: 10,
            confirmSeconds: 25,
            gazeWatchSeconds: 5,
            notLookingDurationSeconds: 8,
            gazeFreshnessSeconds: 10,
            stampGraceSeconds: 15,
            cooldownSeconds: 30,
            breakDurationSeconds: 60,
            promptTimeoutSeconds: 8
        )
    }
}
