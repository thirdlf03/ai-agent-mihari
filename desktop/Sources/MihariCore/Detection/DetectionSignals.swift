import Foundation

/// 判定の材料。1 回の評価で見るものを全部ここに集める。
///
/// 実際の OS 呼び出しや HTTP は一切含まない。だから机上でテストできる。
public struct DetectionSignals: Equatable, Sendable {

    /// Mac が無操作だった秒数。
    public let macIdleSeconds: TimeInterval

    /// iPhone の様子。取得できなければ `.unreachable`。
    public let iphone: SpeechRequest.IPhoneState

    /// iPhone で開いているアプリ名。操作中でなければ nil。
    public let iphoneForegroundApp: String?

    /// いま音楽が鳴っているか。
    ///
    /// 「音楽を止めて説教」は、止める音楽が無ければ空振りする。
    /// 鳴っているときだけ画面を覆うようにするための材料。
    public let music: NowPlaying

    /// 最後に Touch ID の在席スタンプを押してからの秒数。一度も押していなければ `nil`。
    public let secondsSinceStamp: TimeInterval?

    /// 直前まで前面にあったアプリ名。
    public let frontmostApp: String?

    public init(
        macIdleSeconds: TimeInterval,
        iphone: SpeechRequest.IPhoneState = .unreachable,
        iphoneForegroundApp: String? = nil,
        music: NowPlaying = .silent,
        secondsSinceStamp: TimeInterval? = nil,
        frontmostApp: String? = nil
    ) {
        self.macIdleSeconds = max(0, macIdleSeconds)
        self.iphone = iphone
        self.iphoneForegroundApp = iphoneForegroundApp
        self.music = music
        self.secondsSinceStamp = secondsSinceStamp
        self.frontmostApp = frontmostApp
    }

    /// iPhone を触っているか。セリフの区分(`〜Phone`)を選ぶのに使う。
    public var isOnPhone: Bool { iphone == .active }
}
