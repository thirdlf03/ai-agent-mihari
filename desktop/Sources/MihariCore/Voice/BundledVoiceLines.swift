import Foundation
import os

/// 同封したセリフの区分。`Resources/voice/lines.json` の `kinds` のキーと一致する。
public enum BundledVoiceKind: String, Sendable, CaseIterable, Identifiable {
    // ペットのひとりごと(`PetSpeechLines.Kind` と同じ名前)。
    case greeting
    case idle
    case dragging
    case wake
    case watchStart
    case breakEnd
    case focusStreak
    // 在席スタンプの演出(これも `PetSpeechLines.Kind` と同じ名前)。
    case stampReach
    case stampTouched
    case stampMissed
    case stampTimeout
    // 検知のセリフ。区分の選び方は bridge の `fallback.py` と同じ。
    case nudge
    case warn
    case expose
    case iphoneActive
    case sleeping
    case absent
    /// 説教オーバーレイの本文。
    case sermon
    // 監視ループ v2 の区分(疑い 1 → 疑い 2 → 疑い 3 → 晒し → メンヘラモード)。
    // ここも `PetSpeechLines.Kind` と同じ名前。
    case suspectReach
    case suspectReachPhone
    case suspectTouched
    case suspectMissed
    case suspectTimeout
    case askQuestion
    case askQuestionPhone
    case gestureYes
    case gestureNo
    case askTimeout
    case finalWarn
    case finalWarnPhone
    case clingy1
    case clingy2
    case clingy3
    case clingyEvidence
    case returned

    public var id: String { rawValue }

    /// 画面に出す説明。
    public var label: String {
        switch self {
        case .greeting: return "挨拶(クリック)"
        case .idle: return "ひとりごと(待機)"
        case .dragging: return "ドラッグ"
        case .wake: return "起こされた"
        case .watchStart: return "監視の開始"
        case .breakEnd: return "休憩明け"
        case .focusStreak: return "集中継続(褒め)"
        case .stampReach: return "在席スタンプ・指を出す"
        case .stampTouched: return "在席スタンプ・成功"
        case .stampMissed: return "在席スタンプ・空振り"
        case .stampTimeout: return "在席スタンプ・時間切れ"
        case .nudge: return "疑い"
        case .warn: return "確定・声だけ"
        case .expose: return "確定・晒す"
        case .iphoneActive: return "iPhone 操作中"
        case .sleeping: return "寝ている"
        case .absent: return "席にいない"
        case .sermon: return "説教"
        case .suspectReach: return "疑い1・指を出す"
        case .suspectReachPhone: return "疑い1・指を出す(iPhone)"
        case .suspectTouched: return "疑い1・成功"
        case .suspectMissed: return "疑い1・指が違う"
        case .suspectTimeout: return "疑い1・時間切れ"
        case .askQuestion: return "疑い2・質問"
        case .askQuestionPhone: return "疑い2・質問(iPhone)"
        case .gestureYes: return "疑い2・縦に振った"
        case .gestureNo: return "疑い2・横に振った"
        case .askTimeout: return "疑い2・無反応"
        case .finalWarn: return "疑い3・最終警告"
        case .finalWarnPhone: return "疑い3・最終警告(iPhone)"
        case .clingy1: return "メンヘラ・序盤"
        case .clingy2: return "メンヘラ・中盤"
        case .clingy3: return "メンヘラ・終盤"
        case .clingyEvidence: return "メンヘラ・撮り直し"
        case .returned: return "戻ってきた"
        }
    }

    /// 検知の結果からどの区分を喋るかを決める。
    ///
    /// 上から順に当てはまった時点で確定する。並びは bridge の `fallback.py` の `_candidates()` と同じ。
    public static func forDetection(
        vision: SpeechRequest.VisionLabel,
        iphone: SpeechRequest.IPhoneState,
        escalation: SpeechRequest.Escalation
    ) -> BundledVoiceKind {
        if vision == .sleeping { return .sleeping }
        if vision == .absent { return .absent }
        if iphone == .active { return .iphoneActive }
        switch escalation {
        case .nudge: return .nudge
        case .warn: return .warn
        case .expose: return .expose
        }
    }
}

/// 同封したセリフ 1 本と、あればその音声。
public struct BundledVoiceLine: Sendable, Equatable {
    /// 吹き出しに出す文。
    public let text: String
    /// 読み上げ用の音声(AAC / .m4a)。ファイルが無ければ `nil`。
    public let audio: Data?

    public init(text: String, audio: Data?) {
        self.text = text
        self.audio = audio
    }
}

/// アプリに同封したセリフと音声。`Resources/voice/` をそのまま読む。
///
/// - `lines.json` … セリフ本文の唯一の出どころ。ペットのひとりごとも検知のセリフもここから引く
/// - `<kind>/<NN>.m4a` … `NN` は `lines.json` の配列インデックスの 2 桁ゼロ埋め(`00` 始まり)
///
/// 音声は `scripts/generate_voice_lines.py` が VOICEVOX で作る。ファイルが欠けていても
/// テキストだけは返すので、生成し忘れても喋らなくなるだけで壊れない。
public struct BundledVoiceLines: Sendable {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "voice")

    /// アプリ全体で共有する読み込み済みのセリフ集。
    public static let shared = BundledVoiceLines()

    /// 読み上げに使う話者(VOICEVOX)。
    public let speaker: Int

    /// 区分ごとのセリフ本文。
    private let kinds: [BundledVoiceKind: [String]]
    /// `Resources/voice` の位置。バンドルを見つけられなければ `nil`。
    private let directory: URL?

    /// 同封リソースから読み込む。読めなければ空のまま(テキストも音声も返さない)。
    public init() {
        let directory = Self.locateDirectory()
        self.directory = directory
        guard let directory,
            let data = try? Data(contentsOf: directory.appendingPathComponent("lines.json")),
            let document = try? JSONDecoder().decode(Document.self, from: data)
        else {
            Self.logger.error("同封セリフ(lines.json)を読めなかった")
            self.speaker = 0
            self.kinds = [:]
            return
        }
        self.speaker = document.speaker
        var kinds: [BundledVoiceKind: [String]] = [:]
        for kind in BundledVoiceKind.allCases {
            let usable = (document.kinds[kind.rawValue] ?? [])
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !usable.isEmpty else { continue }
            kinds[kind] = usable
        }
        self.kinds = kinds
    }

    /// 区分のセリフ本文をすべて返す。並びは `lines.json` のまま。
    public func lines(for kind: BundledVoiceKind) -> [String] {
        kinds[kind] ?? []
    }

    /// 区分からランダムに 1 本選ぶ。セリフが無ければ `nil`。
    ///
    /// **セリフを選ぶのと、その音声を取るのはここでまとめて行う。**
    /// 別々に抽選すると、吹き出しの文と流れる声がずれる。
    public func pick(_ kind: BundledVoiceKind) -> BundledVoiceLine? {
        var generator = SystemRandomNumberGenerator()
        return pick(kind, using: &generator)
    }

    /// 区分からランダムに 1 本選ぶ。乱数を渡せるので、テストから並びを固定できる。
    public func pick<Generator: RandomNumberGenerator>(
        _ kind: BundledVoiceKind,
        using generator: inout Generator
    ) -> BundledVoiceLine? {
        let candidates = lines(for: kind)
        guard let index = candidates.indices.randomElement(using: &generator) else { return nil }
        return BundledVoiceLine(text: candidates[index], audio: audio(for: kind, at: index))
    }

    /// 本文から、その音声を引く。`lines.json` に無い文(`speech.json` で差し替えたセリフ)なら `nil`。
    ///
    /// 本文で引くので、抽選した文と音声のインデックスがずれることはない。
    public func audio(for kind: BundledVoiceKind, text: String) -> Data? {
        guard let index = lines(for: kind).firstIndex(of: text) else { return nil }
        return audio(for: kind, at: index)
    }

    /// 区分と番号から音声を読む。ファイルが無ければ `nil`。
    public func audio(for kind: BundledVoiceKind, at index: Int) -> Data? {
        guard let directory else { return nil }
        let url =
            directory
            .appendingPathComponent(kind.rawValue)
            .appendingPathComponent(String(format: "%02d.m4a", index))
        return try? Data(contentsOf: url)
    }

    /// `Resources/voice` を探す。ペットの素材と同じバンドルに入っている。
    private static func locateDirectory() -> URL? {
        guard let bundle = PetResourceBundle.locate() else { return nil }
        if let url = bundle.url(forResource: "voice", withExtension: nil) { return url }
        return bundle.resourceURL?.appendingPathComponent("voice")
    }

    /// `lines.json` の形。
    private struct Document: Decodable {
        let speaker: Int
        let kinds: [String: [String]]
    }
}
