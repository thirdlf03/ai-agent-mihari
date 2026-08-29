import Foundation

/// ペットのセリフ集。種類ごとに候補を持ち、その中から 1 つを選んで喋らせる。
struct PetSpeechLines: Codable, Sendable {
    /// セリフの種類。`speech.json` のキー名と一致する。
    enum Kind: String, CaseIterable, CodingKey {
        /// クリックされたときの挨拶。
        case greeting
        /// 作業中。
        case running
        /// 入力や確認を待っているとき。
        case needsInput
        /// 完了したとき。
        case ready
        /// 失敗して止まっているとき。
        case blocked
        /// 待機中のひとりごと。
        case idle
        /// ドラッグされ始めたとき。
        case dragging
        /// 起こされたとき。
        case wake
    }

    /// コードに埋め込んだ既定のセリフ。`speech.json` が無いときはこれを使う。
    static let builtIn = PetSpeechLines(lines: [
        .greeting: [
            "こんにちは。", "呼びました?", "なんでしょう?", "はい、ここに。",
            "お呼びですか?", "ご用ですか?", "見ていましたよ。",
            "何かお手伝いできますか?", "今日もよろしくお願いします。",
            "そんなに触ると、くすぐったいです。",
        ],
        .running: [
            "デバイスを探しています…", "少々お待ちを。", "いま確認しています。",
            "もう少しかかります。", "順番に見ています。", "接続を調べています…",
            "もうすぐ終わります。", "急かさないでくださいね。", "まだ探しています。",
        ],
        .needsInput: [
            "確認をお願いします。", "どうしますか?", "お返事を待っています。",
            "ここで止まっています。", "指示をください。", "続けてもいいですか?",
            "決めてもらえますか?",
        ],
        .ready: [
            "終わりました。", "新しいデバイスが見えました!", "お待たせしました。",
            "できました。", "準備できました。", "見つけましたよ。", "はい、どうぞ。",
            "うまくいきました。",
        ],
        .blocked: [
            "うまくいきませんでした…", "エラーが出ています。", "もう一度試してみますか?",
            "ここで詰まってしまいました。", "つながりませんでした…",
            "少し休んでから、もう一度どうぞ。", "ケーブルは挿さっていますか?",
            "見つかりませんでした。",
        ],
        .idle: [
            "…。", "ふぅ。", "今日はいい天気ですね。", "退屈です。", "静かですね。",
            "…ねむい。", "何か起きるまで、ここにいます。", "お仕事、進んでいますか?",
            "水分、とりました?", "少し休みませんか?", "外は静かですね。", "背伸び…",
            "…あ、ごめんなさい、ぼーっとしていました。", "この辺り、落ち着きます。",
        ],
        .dragging: [
            "わっ。", "どこへ行くんです?", "揺れます…", "持ち上げないでください。",
            "ゆっくりお願いします。", "そこでいいですか?", "高いところは、ちょっと…",
        ],
        .wake: [
            "おはようございます。", "ここにいますよ。", "戻りました。", "起きました。",
            "呼ばれた気がして。", "はい、起きていますよ。", "また会えましたね。",
        ],
    ])

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
