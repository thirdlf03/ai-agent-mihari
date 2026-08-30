import Foundation

/// 「起動してから何時間かは絶対に終了できない」を管理する。
///
/// Touch ID のような「認証を求めておいて結果を無視する」ことは絶対にしない。
/// ロック中は「まだロック中で、あと何分か」を正直に伝えるだけで、時間さえ来れば
/// 終了の意思は必ず尊重する。認証の体裁を取らないぶん、時間による強制だけが
/// 唯一の抑止力になる ―― その代わり嘘はつかない。
public struct QuitTimeLock: Equatable {

    /// この時刻を過ぎるまで終了できない。`nil` はまだロックが設定されていない
    /// (= 監視がまだ始まっていない)状態を表す。
    public private(set) var unlockAt: Date?

    public init(unlockAt: Date? = nil) {
        self.unlockAt = unlockAt
    }

    /// 監視を始めるときに 1 度だけ呼ぶ。`hours` 時間後を解除時刻にする。
    public mutating func lock(for hours: Double, from now: Date = Date()) {
        unlockAt = now.addingTimeInterval(hours * 3600)
    }

    /// いま終了してよいか。
    public func isUnlocked(now: Date = Date()) -> Bool {
        guard let unlockAt else { return true }
        return now >= unlockAt
    }

    /// 「あとN時間M分」の表示/読み上げ用文言。ロックしていなければ `nil`。
    public func remainingDescription(now: Date = Date()) -> String? {
        guard let unlockAt, !isUnlocked(now: now) else { return nil }
        let remainingSeconds = Int(unlockAt.timeIntervalSince(now).rounded(.up))
        let hours = remainingSeconds / 3600
        let minutes = (remainingSeconds % 3600) / 60
        if hours > 0 {
            return "あと\(hours)時間\(minutes)分"
        }
        return "あと\(max(minutes, 1))分"
    }
}
