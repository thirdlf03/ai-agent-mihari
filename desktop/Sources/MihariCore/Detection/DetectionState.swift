import Foundation

/// 見張りの状態。**このアプリの仕様の中心。**
///
/// 正常 → 疑い 1(Touch ID)→ 疑い 2(AirPods の首振り)→ 疑い 3(最終警告)→ 晒し →
/// メンヘラモード、と一方向に進む。どの状態からでも、Mac を触れば正常に戻る。
public enum DetectionState: Equatable, Sendable {

    /// 手が動いている。何もしない。
    case normal

    /// 疑っている。`stage` は 1 / 2 / 3 で、段ごとに「チェック中」と「チェック後の待ち」がある。
    case suspect(stage: Int)

    /// 証拠を撮って Discord へ送っている最中。
    case exposing

    /// メンヘラモード。`since` は入った時刻、`count` はここまでに投げた投稿の数。
    case clingy(since: Date, count: Int)

    /// 疑いの最初の段。
    public static let firstSuspectStage = 1
    /// 疑いの最後の段。ここから先は晒しに進む。
    public static let lastSuspectStage = 3

    /// ログと Logger に出す識別子。表示用ではないので状態の種類だけを表す。
    public var key: String {
        switch self {
        case .normal: return "normal"
        case .suspect(let stage): return "suspect\(stage)"
        case .exposing: return "exposing"
        case .clingy: return "clingy"
        }
    }

    /// 画面に出す日本語のラベル。疑いは何回目か、メンヘラは何回投げたかまで出す。
    public var label: String {
        switch self {
        case .normal: return "正常"
        case .suspect(let stage): return "疑い \(stage) 回目"
        case .exposing: return "晒し中"
        case .clingy(_, let count): return "メンヘラ(\(count) 回目)"
        }
    }

    /// 疑いならその段。それ以外は `nil`。
    public var suspectStage: Int? {
        guard case .suspect(let stage) = self else { return nil }
        return stage
    }

    /// ペットに渡すエスカレーション段階。
    public var escalationStage: Int {
        switch self {
        case .normal: return 0
        case .suspect(let stage): return stage
        case .exposing: return PetEvent.exposingStage
        case .clingy: return PetEvent.clingyStage
        }
    }
}

/// 証拠として何を撮るか。
///
/// ここが「分岐」の中身。Mac が止まっているときに、iPhone を触っているかどうかで撮る先が変わる。
public enum EvidenceKind: String, Equatable, Sendable {
    /// Mac のカメラで顔を撮る。iPhone からも反応が無い＝本人が寝ているか席にいない。
    case macCamera
    /// iPhone の画面を撮る。Mac は放置して iPhone を触っている＝何を見ているかを晒す。
    case iphoneScreenshot
    /// 証拠は取らない。
    case none

    /// 添付するときのファイル名。
    public var filename: String {
        switch self {
        case .macCamera: return "camera.png"
        case .iphoneScreenshot: return "iphone.png"
        case .none: return "evidence.png"
        }
    }

    /// iPhone の様子から撮る先を決める。
    public static func forEvidence(iphone: SpeechRequest.IPhoneState) -> EvidenceKind {
        switch iphone {
        case .active:
            // Mac は放置して iPhone を触っている。何を見ているかを晒す。
            return .iphoneScreenshot
        case .idle, .unreachable:
            // iPhone からも反応が無い。寝ているか席にいないので、顔を撮る。
            return .macCamera
        }
    }
}

/// 1 回の評価の結論。記録と画面に出すためのもので、次に何をするかは状態機械が決める。
public struct DetectionDecision: Equatable, Sendable {
    public let state: DetectionState
    public let evidence: EvidenceKind
    /// なぜそう判断したか。ログに残す。
    public let reason: String

    public init(state: DetectionState, evidence: EvidenceKind = .none, reason: String) {
        self.state = state
        self.evidence = evidence
        self.reason = reason
    }

    /// 何も起きない結論。
    public static func idle(reason: String) -> DetectionDecision {
        DetectionDecision(state: .normal, evidence: .none, reason: reason)
    }
}

/// デバッグメニューの「実際に進める」で選べる操作。
///
/// 見た目だけを再現する偽 `PetEvent` と違い、**本物の遷移・撮影・投稿が走る。**
public enum DetectionDebugStep: String, CaseIterable, Sendable {
    /// 疑い 1 に入って、すぐ Touch ID を確かめる。
    case touchIDCheck
    /// 疑い 2 に入って、すぐ首振りを尋ねる。
    case headGestureCheck
    /// 疑い 3 に入って、最終警告だけ喋る。
    case finalWarning
    /// いま晒す。証拠を撮って Discord へ送り、メンヘラモードに入る。
    case expose
    /// メンヘラモードを始める。
    case startClingy
    /// メンヘラモードを終える(戻ってきた扱い)。
    case endClingy

    /// メニューに出す項目名。
    public var title: String {
        switch self {
        case .touchIDCheck: return "今すぐ Touch ID 確認"
        case .headGestureCheck: return "今すぐ首振り確認"
        case .finalWarning: return "今すぐ最終警告"
        case .expose: return "今すぐ晒す(撮影・投稿する)"
        case .startClingy: return "メンヘラを始める(投稿する)"
        case .endClingy: return "メンヘラを終える(戻ってきた扱い)"
        }
    }
}

extension DefaultStringInterpolation {
    /// 秒数を読みやすく差し込む。ログと Discord の文面の両方で使う。
    mutating func appendInterpolation(seconds value: TimeInterval) {
        let total = Int(value.rounded())
        if total < 60 {
            appendLiteral("\(total)秒")
        } else {
            appendLiteral("\(total / 60)分")
        }
    }
}

/// 経過時間を「12 分 34 秒」の形で書く。メンヘラモードの「戻ってこないまま」に使う。
public enum ElapsedText {
    public static func minutesAndSeconds(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        guard total >= 60 else { return "\(total) 秒" }
        return "\(total / 60) 分 \(total % 60) 秒"
    }
}
