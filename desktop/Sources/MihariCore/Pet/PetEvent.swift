import Foundation

/// サボり検知の状態機械（#9）が今どの段階にいるか。
public enum SaboriState: String, Sendable, Equatable, CaseIterable {
    case normal
    case suspected
    case confirmed

    /// 画面表示用の日本語ラベル。
    public var label: String {
        switch self {
        case .normal: return "正常"
        case .suspected: return "疑い"
        case .confirmed: return "サボり確定"
        }
    }
}

/// 直近の撮影画像に Vision（#11）が付けたラベル。まだ撮っていなければ `.none`。
public enum VisionLabel: String, Sendable, Equatable, CaseIterable {
    case asleep
    case lookingAway
    case absent
    case none

    /// 画面表示用の日本語ラベル。
    public var label: String {
        switch self {
        case .asleep: return "寝てる"
        case .lookingAway: return "よそ見"
        case .absent: return "不在"
        case .none: return "なし"
        }
    }
}

/// ペットからの はい/いいえ の問いかけ。
///
/// `onAnswer` は回答が決まった瞬間に一度だけ呼ぶコールバック。ボタンのタップからも、
/// AirPods の首振り判定（#18）からも、同じコールバックを呼べば分岐できる。
public struct PetYesNoPrompt: Sendable {
    public let question: String
    /// 問いかけを読み上げる音声(同封の .m4a)。無ければ吹き出しだけ出す。
    ///
    /// 問いかけは吹き出しがボタンに変わるので、普通のセリフとしては喋らせられない。
    /// 出した瞬間に鳴らせるよう、問いかけ自身に音声を持たせる。
    public let audio: Data?
    public let onAnswer: @Sendable (Bool) -> Void

    public init(question: String, audio: Data? = nil, onAnswer: @escaping @Sendable (Bool) -> Void) {
        self.question = question
        self.audio = audio
        self.onAnswer = onAnswer
    }
}

/// 検知エンジンからペットに渡す1件分のイベント。
///
/// ペット本体の実装が暫定の画像1枚でも本実装でも、この型を `PetPresenting.present(_:)` に
/// 渡しさえすれば反映される。検知側はペットの中身を一切知らなくてよい。
public struct PetEvent: Sendable {
    /// エスカレーション段階の下限。負の値は組み立て時に丸める。
    public static let minimumEscalationStage = 0

    /// 晒し(exposing)のエスカレーション段階。疑い 3 段の続き。
    public static let exposingStage = 4
    /// メンヘラモード(clingy)のエスカレーション段階。ここが最終段。
    public static let clingyStage = 5

    /// 正常 / 疑い / サボり確定。
    public let state: SaboriState
    /// エスカレーション段階（0 始まり）。説教の強さなどの目安に使う想定。
    public let escalationStage: Int
    /// 吹き出しに表示するセリフ。空文字なら吹き出しは出さない。
    public let line: String
    /// セリフの読み上げ用の音声(WAV)。付いていなければ `nil`。
    ///
    /// 取れた瞬間に鳴らすと、吹き出しを待たせているあいだに声だけ先に出てしまう。
    /// 鳴らすのはペット側に任せ、ここでは吹き出しと一緒に運ぶだけにする。
    public let audio: Data?
    /// 直近の撮影画像に付いた Vision のラベル。
    public let visionLabel: VisionLabel
    /// はい/いいえ の問いかけ。問いかけが無いイベントでは `nil`。
    public let prompt: PetYesNoPrompt?

    public init(
        state: SaboriState,
        escalationStage: Int,
        line: String,
        audio: Data? = nil,
        visionLabel: VisionLabel = .none,
        prompt: PetYesNoPrompt? = nil
    ) {
        self.state = state
        // 負の段階は意味を持たないため 0 に丸める。呼び出し側の計算ミスを黙って吸収する。
        self.escalationStage = max(escalationStage, Self.minimumEscalationStage)
        self.line = line
        self.audio = audio
        self.visionLabel = visionLabel
        self.prompt = prompt
    }
}
