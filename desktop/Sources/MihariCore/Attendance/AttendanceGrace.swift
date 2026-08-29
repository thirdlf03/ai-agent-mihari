import Foundation

/// スタンプ直後の猶予期間を判定する純粋なロジック。
///
/// サボり検知の状態機械(#9)は、直近でスタンプが押されていれば「在席が証明済み」として
/// アイドル判定を見送るためにここを参照する想定。副作用を持たず `[AttendanceStamp]` と
/// 現在時刻だけから答えを出すので、#9 側からもモック無しでそのまま呼べる。
public enum AttendanceGrace {

    /// スタンプ直後、何秒間はサボり判定を見送るか。
    public static let defaultGracePeriod: TimeInterval = 5 * 60

    /// 直近のスタンプから経過した秒数。履歴が空なら `nil`。
    ///
    /// スタンプが未来時刻(時計のずれなど)にある場合も、経過秒数としてそのまま
    /// 負の値を返す。猶予判定側で 0 未満を弾く。
    public static func secondsSinceLastStamp(stamps: [AttendanceStamp], now: Date) -> TimeInterval? {
        guard let last = latestStamp(in: stamps) else { return nil }
        return now.timeIntervalSince(last.stampedAt)
    }

    /// いま猶予期間中かどうか。
    public static func isWithinGracePeriod(
        stamps: [AttendanceStamp],
        now: Date,
        gracePeriod: TimeInterval = defaultGracePeriod
    ) -> Bool {
        guard let elapsed = secondsSinceLastStamp(stamps: stamps, now: now) else { return false }
        return elapsed >= 0 && elapsed < gracePeriod
    }

    /// 猶予の残り秒数。猶予期間外(未経過なし、または経過済み)なら 0。
    public static func remainingGraceSeconds(
        stamps: [AttendanceStamp],
        now: Date,
        gracePeriod: TimeInterval = defaultGracePeriod
    ) -> TimeInterval {
        guard let elapsed = secondsSinceLastStamp(stamps: stamps, now: now), elapsed >= 0, elapsed < gracePeriod else {
            return 0
        }
        return gracePeriod - elapsed
    }

    private static func latestStamp(in stamps: [AttendanceStamp]) -> AttendanceStamp? {
        stamps.max { $0.stampedAt < $1.stampedAt }
    }
}
