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
    public let vision: VisionLabel

    enum CodingKeys: String, CodingKey {
        case idleSeconds = "idle_seconds"
        case escalation
        case frontmostApp = "frontmost_app"
        case iphone
        case vision
    }

    public init(
        idleSeconds: Int,
        escalation: Escalation = .nudge,
        frontmostApp: String? = nil,
        iphone: IPhoneState = .unreachable,
        vision: VisionLabel = .unknown
    ) {
        // 負の秒数はデーモンが 422 で弾く。手前で丸めて、無駄な往復をしない。
        self.idleSeconds = max(0, idleSeconds)
        self.escalation = escalation
        self.frontmostApp = frontmostApp
        self.iphone = iphone
        self.vision = vision
    }
}

/// セリフと、あれば読み上げ用の音声。
public struct SpokenLine: Decodable, Equatable, Sendable {
    public let text: String
    /// LLM が作ったなら `true`、固定文言に落ちたなら `false`。
    public let fromLLM: Bool
    /// 固定文言に落ちた理由。
    public let fallbackReason: String?
    /// WAV を base64 にしたもの。VOICEVOX が起動していなければ `nil`。
    public let audio: String?
    /// 音声を作れなかった理由。
    public let audioError: String?

    enum CodingKeys: String, CodingKey {
        case text
        case fromLLM = "from_llm"
        case fallbackReason = "fallback_reason"
        case audio
        case audioError = "audio_error"
    }

    public init(
        text: String,
        fromLLM: Bool,
        fallbackReason: String? = nil,
        audio: String? = nil,
        audioError: String? = nil
    ) {
        self.text = text
        self.fromLLM = fromLLM
        self.fallbackReason = fallbackReason
        self.audio = audio
        self.audioError = audioError
    }

    /// base64 を解いた WAV。
    public var audioData: Data? {
        audio.flatMap { Data(base64Encoded: $0) }
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

    enum CodingKeys: String, CodingKey {
        case llmConfigured = "llm_configured"
        case llmModel = "llm_model"
        case voicevoxURL = "voicevox_url"
        case voicevoxSpeaker = "voicevox_speaker"
        case voicevoxReachable = "voicevox_reachable"
        case cachedAudio = "cached_audio"
    }

    public init(
        llmConfigured: Bool,
        llmModel: String,
        voicevoxURL: String,
        voicevoxSpeaker: Int,
        voicevoxReachable: Bool,
        cachedAudio: Int
    ) {
        self.llmConfigured = llmConfigured
        self.llmModel = llmModel
        self.voicevoxURL = voicevoxURL
        self.voicevoxSpeaker = voicevoxSpeaker
        self.voicevoxReachable = voicevoxReachable
        self.cachedAudio = cachedAudio
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
