import Foundation

/// 「はい/いいえ」を尋ねた結果。ペットの問いかけ UI(#16)はこれで分岐する。
public enum HeadGestureResponse: Sendable, Equatable {
    /// うなずきで「はい」と答えた。
    case yes
    /// 首振りで「いいえ」と答えた。
    case no
    /// 時間内に判定できる動きがなかった。
    case timedOut
    /// AirPods 未接続・非対応機種・権限なしなどで、質問自体を出せなかった。
    case unavailable(reason: String)
}
