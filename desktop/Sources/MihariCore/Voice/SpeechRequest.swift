import Foundation

/// 「いま何が起きているか」をデーモンに渡すための値。
///
/// Python 側の `SpeechContext` と 1 対 1 に対応する。
/// 知らない値が来ても向こうが既定に倒すので、片方だけ先に更新しても喋り続ける。
public struct SpeechRequest: Encodable, Equatable, Sendable {

    /// サボりに対する当たりの強さ。
    public enum Escalation: String, Encodable, Sendable, CaseIterable {
        /// まだ疑っているだけ。軽く声をかける。
        case nudge
        /// サボり確定。音楽を止めて話を聞かせる段階。
        case warn
        /// 証拠を Discord に晒す段階。
        case expose
    }

    /// iPhone の様子。
    public enum IPhoneState: String, Encodable, Sendable {
        case active
        case idle
        case unreachable
    }

    /// 撮った写真に対する見立て。
    public enum VisionLabel: String, Encodable, Sendable {
        case sleeping
        case lookingAway = "looking_away"
        case absent
        case unknown
    }

    public let idleSeconds: Int
    public let escalation: Escalation
    public let frontmostApp: String?
    public let iphone: IPhoneState
    /// iPhone で開いているアプリ名(表示名、無ければ bundle ID)。操作中でなければ `nil`。
    ///
    /// `nil` ならキーごと出さない ＝ 従来どおりの要求になる。
    public let iphoneApp: String?
    public let vision: VisionLabel
    /// iPhone の画面(PNG)。添えるとデーモン側が「何のアプリで何をしているか」を読む。
    ///
    /// `JSONEncoder` の既定は base64 なので、そのまま base64 文字列として乗る。
    /// `nil` ならキーごと出さない ＝ 従来どおりの要求になる。
    public var screenshotPNG: Data?

    enum CodingKeys: String, CodingKey {
        case idleSeconds = "idle_seconds"
        case escalation
        case frontmostApp = "frontmost_app"
        case iphone
        case iphoneApp = "iphone_app"
        case vision
        case screenshotPNG = "screenshot_png"
    }

    public init(
        idleSeconds: Int,
        escalation: Escalation = .nudge,
        frontmostApp: String? = nil,
        iphone: IPhoneState = .unreachable,
        iphoneApp: String? = nil,
        vision: VisionLabel = .unknown,
        screenshotPNG: Data? = nil
    ) {
        // 負の秒数はデーモンが 422 で弾く。手前で丸めて、無駄な往復をしない。
        self.idleSeconds = max(0, idleSeconds)
        self.escalation = escalation
        self.frontmostApp = frontmostApp
        self.iphone = iphone
        self.iphoneApp = iphoneApp
        self.vision = vision
        self.screenshotPNG = screenshotPNG
    }
}

/// セリフと、あれば読み上げ用の音声。
public struct SpokenLine: Decodable, Equatable, Sendable {

    /// 送ったスクショから読み取れた「いま何をしているか」。
    public struct ScreenReading: Decodable, Sendable, Equatable {
        /// 何のアプリか。読めなければ `nil`。
        public var app: String?
        /// そこで何をしているか。
        public var activity: String
        /// `"work"` / `"slacking"` / `"neutral"` / `"unknown"` のいずれか。
        /// 知らない値が増えても壊れないよう、列挙ではなく文字列のまま持つ。
        public var category: String

        public init(app: String? = nil, activity: String, category: String) {
            self.app = app
            self.activity = activity
            self.category = category
        }
    }

    public let text: String
    /// LLM が作ったなら `true`、固定文言に落ちたなら `false`。
    public let fromLLM: Bool
    /// 固定文言に落ちた理由。
    public let fallbackReason: String?
    /// WAV を base64 にしたもの。VOICEVOX が起動していなければ `nil`。
    public let audio: String?
    /// 音声を作れなかった理由。
    public let audioError: String?
    /// 画面を読めたときだけ入る。スクショを送っていなければ `nil`。
    public var screen: ScreenReading?
    /// スクショを送ったのに読めなかった理由(キー未設定・タイムアウトなど)。
    public var screenError: String?

    enum CodingKeys: String, CodingKey {
        case text
        case fromLLM = "from_llm"
        case fallbackReason = "fallback_reason"
        case audio
        case audioError = "audio_error"
        case screen
        case screenError = "screen_error"
    }

    public init(
        text: String,
        fromLLM: Bool,
        fallbackReason: String? = nil,
        audio: String? = nil,
        audioError: String? = nil,
        screen: ScreenReading? = nil,
        screenError: String? = nil
    ) {
        self.text = text
        self.fromLLM = fromLLM
        self.fallbackReason = fallbackReason
        self.audio = audio
        self.audioError = audioError
        self.screen = screen
        self.screenError = screenError
    }

    /// base64 を解いた WAV。
    public var audioData: Data? {
        audio.flatMap { Data(base64Encoded: $0) }
    }
}

/// `POST /voice/screen` の応答。セリフも音声も作らせず、画面を読ませるだけ。
///
/// 同封音声のモードでは bridge にセリフを作らせないが、Discord の文面には
/// 「何のアプリで何をしていたか」を入れたい。そこだけをここで読ませる。
public struct ScreenReadResult: Decodable, Equatable, Sendable {
    /// 読み取れた画面。読ませていない・読めなかったなら `nil`。
    public var screen: SpokenLine.ScreenReading?
    /// 読めなかった理由(キー未設定・タイムアウトなど)。
    public var screenError: String?

    enum CodingKeys: String, CodingKey {
        case screen
        case screenError = "screen_error"
    }

    public init(screen: SpokenLine.ScreenReading? = nil, screenError: String? = nil) {
        self.screen = screen
        self.screenError = screenError
    }
}

/// セリフ生成と読み上げが使える状態か。
public struct VoiceStatus: Decodable, Equatable, Sendable {
    public let llmConfigured: Bool
    public let llmModel: String
    public let voicevoxURL: String
    public let voicevoxSpeaker: Int
    public let voicevoxReachable: Bool
    public let cachedAudio: Int
    /// 画面読み取り用の LLM にキーが通っているか。
    public let screenLLMConfigured: Bool
    /// 画面読み取りに使うモデル名。
    public let screenLLMModel: String

    enum CodingKeys: String, CodingKey {
        case llmConfigured = "llm_configured"
        case llmModel = "llm_model"
        case voicevoxURL = "voicevox_url"
        case voicevoxSpeaker = "voicevox_speaker"
        case voicevoxReachable = "voicevox_reachable"
        case cachedAudio = "cached_audio"
        case screenLLMConfigured = "screen_llm_configured"
        case screenLLMModel = "screen_llm_model"
    }

    public init(
        llmConfigured: Bool,
        llmModel: String,
        voicevoxURL: String,
        voicevoxSpeaker: Int,
        voicevoxReachable: Bool,
        cachedAudio: Int,
        screenLLMConfigured: Bool = false,
        screenLLMModel: String = ""
    ) {
        self.llmConfigured = llmConfigured
        self.llmModel = llmModel
        self.voicevoxURL = voicevoxURL
        self.voicevoxSpeaker = voicevoxSpeaker
        self.voicevoxReachable = voicevoxReachable
        self.cachedAudio = cachedAudio
        self.screenLLMConfigured = screenLLMConfigured
        self.screenLLMModel = screenLLMModel
    }

    /// 画面読み取りは後から生えたフィールド。
    /// 古いデーモンに繋いだだけで状態表示が丸ごと落ちないよう、無ければ既定に倒す。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        llmConfigured = try container.decode(Bool.self, forKey: .llmConfigured)
        llmModel = try container.decode(String.self, forKey: .llmModel)
        voicevoxURL = try container.decode(String.self, forKey: .voicevoxURL)
        voicevoxSpeaker = try container.decode(Int.self, forKey: .voicevoxSpeaker)
        voicevoxReachable = try container.decode(Bool.self, forKey: .voicevoxReachable)
        cachedAudio = try container.decode(Int.self, forKey: .cachedAudio)
        screenLLMConfigured = try container.decodeIfPresent(Bool.self, forKey: .screenLLMConfigured) ?? false
        screenLLMModel = try container.decodeIfPresent(String.self, forKey: .screenLLMModel) ?? ""
    }

    /// 画面に出す、いま何が足りないかの一言。
    public var summary: String {
        switch (llmConfigured, voicevoxReachable) {
        case (true, true):
            return "セリフも声も使える"
        case (false, true):
            return "声は出るが、セリフは固定文言（ANTHROPIC_API_KEY 未設定）"
        case (true, false):
            return "セリフは作れるが無音（VOICEVOX が起動していない）"
        case (false, false):
            return "固定文言・無音（API キーと VOICEVOX の両方が未設定）"
        }
    }
}
