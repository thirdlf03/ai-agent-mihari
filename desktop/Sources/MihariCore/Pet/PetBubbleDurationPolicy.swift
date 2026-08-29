import Foundation

/// 吹き出しの表示時間をセリフの長さから決めるための純粋なロジック。
///
/// 短すぎるセリフでも読めるだけの最低時間を確保しつつ、長いセリフでもいつまでも
/// 居座らないよう上限で丸める。
public enum PetBubbleDurationPolicy {
    /// 表示時間の下限（秒）。1文字も無いくらい短いセリフでもこれだけは出す。
    public static let minimumSeconds: TimeInterval = 2.5
    /// 表示時間の上限（秒）。長いセリフでもここで打ち切る。
    public static let maximumSeconds: TimeInterval = 8.0
    /// 1文字あたりに足す秒数。日本語を読む速度の目安として粗く決めた値。
    public static let secondsPerCharacter: TimeInterval = 0.15

    /// セリフの文字数に応じた表示時間（秒）を返す。
    public static func duration(for line: String) -> TimeInterval {
        let raw = TimeInterval(line.count) * secondsPerCharacter
        return min(max(raw, minimumSeconds), maximumSeconds)
    }
}
