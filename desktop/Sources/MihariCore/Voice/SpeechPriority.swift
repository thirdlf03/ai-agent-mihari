import Foundation

/// 声の強さ。値が大きいほど強い(`chatter < detection`)。
///
/// 声の経路は 2 本ある。サボり検知のセリフと、ペットのひとりごと。
/// 音を出す口は 1 つしかないので、どちらを鳴らすかをこの優先度で決める。
public enum SpeechPriority: Sendable, Comparable {
    /// ペットのひとりごと。検知のセリフには譲る。
    case chatter
    /// サボり検知のセリフ。鳴っているものを止めてでも必ず鳴らす。
    case detection
}

/// 鳴らしていいかを決める。
///
/// **検知のセリフは必ず鳴る。** サボりを見つけたのに、ひとりごとが鳴っていたせいで
/// 何も言わなかった、という壊れ方をさせない。逆にひとりごとは、検知のセリフに
/// かぶせない。溜めて後から鳴らすこともしない(状況が変わったあとの独り言に意味がない)。
///
/// 音を出す処理から切り離してあるので、判定だけを単体テストで固定できる。
public enum SpeechPlaybackArbiter {

    /// 判定の結果。
    public enum Verdict: Equatable {
        /// 鳴らす。何か鳴っていれば止めて差し替える。
        case play
        /// 鳴らさずに捨てる。
        case drop
    }

    /// - Parameters:
    ///   - current: いま再生中の優先度。何も鳴っていなければ `nil`。
    ///   - requested: これから鳴らしたい優先度。
    public static func decide(current: SpeechPriority?, requested: SpeechPriority) -> Verdict {
        switch requested {
        case .detection:
            return .play
        case .chatter:
            return current == .detection ? .drop : .play
        }
    }
}
