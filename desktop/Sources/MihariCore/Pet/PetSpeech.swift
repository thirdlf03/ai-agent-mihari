import Foundation

/// ペットのセリフ集。種類ごとに候補を持ち、その中から 1 つを選んで喋らせる。
struct PetSpeechLines: Codable, Sendable {
    /// セリフの種類。`speech.json` のキー名と一致する。
    enum Kind: String, CaseIterable, CodingKey {
        /// クリックされたときの挨拶。
        case greeting
        /// 待機中のひとりごと。
        case idle
        /// ドラッグされ始めたとき。
        case dragging
        /// 起こされたとき。
        case wake
        /// 監視が始まったとき。
        case watchStart
        /// 休憩が明けて監視に戻ったとき。
        case breakEnd
        /// 集中が続いているとき(褒める)。
        case focusStreak
        /// 在席スタンプで指を差し出したとき。
        case stampReach
        /// 在席スタンプの認証に成功したとき。
        case stampTouched
        /// 在席スタンプの認証に失敗・キャンセルしたとき。
        case stampMissed
        /// 在席スタンプの認証を時間切れで打ち切ったとき。
        case stampTimeout

        /// 同封セリフ側の同じ区分。名前は `lines.json` のキーと揃えてある。
        var bundled: BundledVoiceKind {
            switch self {
            case .greeting: return .greeting
            case .idle: return .idle
            case .dragging: return .dragging
            case .wake: return .wake
            case .watchStart: return .watchStart
            case .breakEnd: return .breakEnd
            case .focusStreak: return .focusStreak
            case .stampReach: return .stampReach
            case .stampTouched: return .stampTouched
            case .stampMissed: return .stampMissed
            case .stampTimeout: return .stampTimeout
            }
        }
    }

    /// 既定のセリフ。`Resources/voice/lines.json` が唯一の出どころで、`speech.json` が無ければこれを使う。
    static let builtIn: PetSpeechLines = {
        var lines: [Kind: [String]] = [:]
        for kind in Kind.allCases {
            let values = BundledVoiceLines.shared.lines(for: kind.bundled)
            guard !values.isEmpty else { continue }
            lines[kind] = values
        }
        return PetSpeechLines(lines: lines)
    }()

    /// 種類ごとのセリフ候補。候補が空の種類は持たない。
    private var lines: [Kind: [String]]

    private init(lines: [Kind: [String]]) {
        self.lines = lines
    }

    /// `speech.json` を読む。書かれていないキーや空の候補は持たない。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Kind.self)
        var lines: [Kind: [String]] = [:]
        for kind in Kind.allCases {
            let values = try container.decodeIfPresent([String].self, forKey: kind) ?? []
            let usable = values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !usable.isEmpty else { continue }
            lines[kind] = usable
        }
        self.lines = lines
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Kind.self)
        for kind in Kind.allCases {
            guard let values = lines[kind] else { continue }
            try container.encode(values, forKey: kind)
        }
    }

    /// 指定した種類のセリフを 1 つ選ぶ。候補が無ければ nil。
    func randomLine(for kind: Kind) -> String? {
        lines[kind]?.randomElement()
    }

    /// `other` が持っている種類だけを差し替えたセリフ集を返す。
    func overridden(by other: PetSpeechLines) -> PetSpeechLines {
        PetSpeechLines(lines: lines.merging(other.lines) { _, replacement in replacement })
    }

    /// ペットの `speech.json` を既定のセリフに重ねて読み込む。無い・壊れている場合は既定のまま。
    static func load(from url: URL?) -> PetSpeechLines {
        guard let url,
            let data = try? Data(contentsOf: url),
            let custom = try? JSONDecoder().decode(PetSpeechLines.self, from: data)
        else {
            return builtIn
        }
        return builtIn.overridden(by: custom)
    }
}
