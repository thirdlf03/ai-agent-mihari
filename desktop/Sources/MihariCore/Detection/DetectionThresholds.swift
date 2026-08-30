import Foundation

/// 判定の閾値。**すべて要調整。** デモしながら詰める前提で、全部外から差し替えられるようにしている。
public struct DetectionThresholds: Equatable, Sendable {

    /// ここを超えたら疑い 1。すぐ Touch ID を確かめに行く。
    public let suspectSeconds: TimeInterval

    /// 疑いの段が 1 つ上がるまでの待ち時間。チェックが空振りしてから次の段へ進むまで。
    public let stageIntervalSeconds: TimeInterval

    /// 疑い 1 の Touch ID を待つ時間。`AttendanceModel` の打ち切りと同じ値を使う。
    public let touchIDTimeoutSeconds: TimeInterval

    /// 疑い 2 の問いかけの返事を待つ時間。これを過ぎたら無反応として次の待ちに入る。
    public let promptTimeoutSeconds: TimeInterval

    /// メンヘラモードでテキストだけの投稿を投げる間隔。
    public let clingyIntervalSeconds: TimeInterval

    /// メンヘラモードで証拠を撮り直す間隔。この回はテキストだけの投稿と重ねず 1 件にまとめる。
    public let clingyEvidenceIntervalSeconds: TimeInterval

    /// メニューの「休憩する」で見張りを止めておく時間。
    /// この間は材料を集める前に評価を打ち切る。撮らない・送らない・喋らない。
    public let breakDurationSeconds: TimeInterval

    /// メニューの在席スタンプを押した直後の猶予。
    /// 「いま席にいる」と本人が示したのに疑い始めると、ただの嫌がらせになる。
    public let stampGraceSeconds: TimeInterval

    /// 正常が続いているとき、この間隔ごとにペットが褒める。
    /// 疑い以上の判定・休憩の開始・監視の停止で数え直す。
    public let focusStreakIntervalSeconds: TimeInterval

    public init(
        suspectSeconds: TimeInterval = 60,
        stageIntervalSeconds: TimeInterval = 30,
        touchIDTimeoutSeconds: TimeInterval = AttendanceModel.defaultAuthenticationTimeout,
        promptTimeoutSeconds: TimeInterval = 20,
        clingyIntervalSeconds: TimeInterval = 60,
        clingyEvidenceIntervalSeconds: TimeInterval = 300,
        breakDurationSeconds: TimeInterval = 900,
        stampGraceSeconds: TimeInterval = AttendanceGrace.defaultGracePeriod,
        focusStreakIntervalSeconds: TimeInterval = 900
    ) {
        self.suspectSeconds = suspectSeconds
        self.stageIntervalSeconds = stageIntervalSeconds
        self.touchIDTimeoutSeconds = touchIDTimeoutSeconds
        self.promptTimeoutSeconds = promptTimeoutSeconds
        self.clingyIntervalSeconds = clingyIntervalSeconds
        // 撮り直しの間隔がテキストの間隔より短いと、毎回が証拠つきになってテキストだけの投稿が消える。
        self.clingyEvidenceIntervalSeconds = max(clingyIntervalSeconds, clingyEvidenceIntervalSeconds)
        self.breakDurationSeconds = breakDurationSeconds
        self.stampGraceSeconds = stampGraceSeconds
        self.focusStreakIntervalSeconds = focusStreakIntervalSeconds
    }

    /// 集中継続の間隔だけを差し替えた閾値を返す。デバッグメニューから 15 分 / 1 分を切り替えるのに使う。
    public func withFocusStreakInterval(_ seconds: TimeInterval) -> DetectionThresholds {
        DetectionThresholds(
            suspectSeconds: suspectSeconds,
            stageIntervalSeconds: stageIntervalSeconds,
            touchIDTimeoutSeconds: touchIDTimeoutSeconds,
            promptTimeoutSeconds: promptTimeoutSeconds,
            clingyIntervalSeconds: clingyIntervalSeconds,
            clingyEvidenceIntervalSeconds: clingyEvidenceIntervalSeconds,
            breakDurationSeconds: breakDurationSeconds,
            stampGraceSeconds: stampGraceSeconds,
            focusStreakIntervalSeconds: seconds
        )
    }

    /// 何か起こりうる最短の無操作秒数。これ未満なら「手が動いている」と見なす。
    ///
    /// 疑いの途中でこの秒数を下回ったら、何か入力があったということなので正常に戻す。
    public var minimumIdleSeconds: TimeInterval {
        min(suspectSeconds, stageIntervalSeconds)
    }

    /// 標準の値。
    public static let standard = DetectionThresholds()

    /// 動作確認用に全部を秒単位まで縮めた値。
    /// 1 分待たずに一連の流れが通るかを見られる。デモの調整にも使う。
    public static let fast = DetectionThresholds(
        suspectSeconds: 15,
        stageIntervalSeconds: 10,
        promptTimeoutSeconds: 8,
        clingyIntervalSeconds: 15,
        clingyEvidenceIntervalSeconds: 60,
        breakDurationSeconds: 60,
        stampGraceSeconds: 15,
        focusStreakIntervalSeconds: 60
    )

    /// 起動時の既定値。
    ///
    /// `MIHARI_FAST_THRESHOLDS=1` を付けて起動すると `fast` で始まる。
    /// 起動したあとはペットの右クリック →「デバッグ」→「検知の閾値」からも切り替えられる。
    public static var `default`: DetectionThresholds {
        ProcessInfo.processInfo.environment["MIHARI_FAST_THRESHOLDS"] == "1" ? .fast : .standard
    }
}
