import Foundation

/// 判定の材料。1 回の評価で見るものを全部ここに集める。
///
/// この型と `DetectionDecision` の組が「どういう入力のときに何をするか」の仕様そのもので、
/// 実際の OS 呼び出しや HTTP は一切含まない。だから机上でテストできる。
public struct DetectionSignals: Equatable, Sendable {

    /// Mac が無操作だった秒数。
    public let macIdleSeconds: TimeInterval

    /// iPhone の様子。取得できなければ `.unreachable`。
    public let iphone: SpeechRequest.IPhoneState

    /// 最後に Touch ID の在席スタンプを押してからの秒数。一度も押していなければ `nil`。
    public let secondsSinceStamp: TimeInterval?

    /// 直前まで前面にあったアプリ名。
    public let frontmostApp: String?

    public init(
        macIdleSeconds: TimeInterval,
        iphone: SpeechRequest.IPhoneState = .unreachable,
        secondsSinceStamp: TimeInterval? = nil,
        frontmostApp: String? = nil
    ) {
        self.macIdleSeconds = max(0, macIdleSeconds)
        self.iphone = iphone
        self.secondsSinceStamp = secondsSinceStamp
        self.frontmostApp = frontmostApp
    }
}

/// サボり具合の段階。
public enum DetectionState: String, Equatable, Sendable, CaseIterable {
    /// 手が動いている。何もしない。
    case normal
    /// 手が止まっている。声をかける段階。
    case suspected
    /// 止まりすぎ。証拠を取って晒す段階。
    case confirmed

    public var label: String {
        switch self {
        case .normal: return "正常"
        case .suspected: return "疑い"
        case .confirmed: return "サボり確定"
        }
    }
}

/// 確定したときに何を証拠として取るか。
///
/// ここが「分岐」の中身。Mac が止まっているときに、iPhone を触っているかどうかで撮る先が変わる。
public enum EvidenceKind: String, Equatable, Sendable {
    /// Mac のカメラで顔を撮る。iPhone からも反応が無い＝本人が寝ているか席にいない。
    case macCamera
    /// iPhone の画面を撮る。Mac は放置して iPhone を触っている＝何を見ているかを晒す。
    case iphoneScreenshot
    /// 証拠は取らない。
    case none
}

/// 1 回の評価の結論。
public struct DetectionDecision: Equatable, Sendable {
    public let state: DetectionState
    public let evidence: EvidenceKind
    /// 声をかけるべきか。
    public let shouldSpeak: Bool
    /// 音楽を止めて全画面で聞かせるべきか。
    public let shouldInterrupt: Bool
    /// なぜそう判断したか。ログと Discord の文面に使う。
    public let reason: String

    public init(
        state: DetectionState,
        evidence: EvidenceKind,
        shouldSpeak: Bool,
        shouldInterrupt: Bool,
        reason: String
    ) {
        self.state = state
        self.evidence = evidence
        self.shouldSpeak = shouldSpeak
        self.shouldInterrupt = shouldInterrupt
        self.reason = reason
    }

    /// 何も起きない結論。
    public static func idle(reason: String) -> DetectionDecision {
        DetectionDecision(
            state: .normal,
            evidence: .none,
            shouldSpeak: false,
            shouldInterrupt: false,
            reason: reason
        )
    }
}
