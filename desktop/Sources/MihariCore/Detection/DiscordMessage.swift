import Foundation

/// Discord に晒すときの材料。
///
/// `DetectionEngine` が記録に残す `reason` と同じ信号から引く。
/// `reason` は記録用に残したままで、投稿の本文はこちらから組み立てる。
public struct DiscordMessageFacts: Equatable, Sendable {

    /// 何を証拠に撮ったか。
    public var evidence: EvidenceKind
    /// カメラで撮ったときの見立て。iPhone のスクショなら `.unknown`。
    public var vision: SpeechRequest.VisionLabel
    /// iPhone の様子。
    public var iphone: SpeechRequest.IPhoneState
    /// iPhone の画面から読み取れた内容。読ませていない・読めなかったなら `nil`。
    public var screen: SpokenLine.ScreenReading?
    /// 「画面を見ていない」が確定の理由になっているときだけ、その秒数。
    public var notLookingSeconds: TimeInterval?
    /// Mac が無操作だった秒数。
    public var macIdleSeconds: TimeInterval
    /// 鳴っていた音楽プレイヤーの名前。鳴っていなければ `nil`。
    public var musicPlayer: String?
    /// 直前まで前面にあったアプリ名。分からなければ `nil`。
    public var frontmostApp: String?

    public init(
        evidence: EvidenceKind,
        vision: SpeechRequest.VisionLabel = .unknown,
        iphone: SpeechRequest.IPhoneState = .unreachable,
        screen: SpokenLine.ScreenReading? = nil,
        notLookingSeconds: TimeInterval? = nil,
        macIdleSeconds: TimeInterval,
        musicPlayer: String? = nil,
        frontmostApp: String? = nil
    ) {
        self.evidence = evidence
        self.vision = vision
        self.iphone = iphone
        self.screen = screen
        self.notLookingSeconds = notLookingSeconds
        self.macIdleSeconds = macIdleSeconds
        self.musicPlayer = musicPlayer
        self.frontmostApp = frontmostApp
    }
}

/// Discord の投稿本文を組み立てる。
///
/// 1 行目で「何をしていたか」を言い、2 行目(小文字表示の `-# `)に事実を並べる。
/// **メンションは付けない。** `<@ID> ` は bridge が本文の先頭に足す。
///
/// OS も HTTP も触らない純粋関数なので、乱数を渡せば出力を固定して検証できる。
public enum DiscordMessageComposer {

    /// 2 行目の頭に付ける、Discord の小文字表示の記法。
    static let subtextPrefix = "\n-# "

    /// 本文を組み立てる。
    public static func compose(_ facts: DiscordMessageFacts) -> String {
        var generator = SystemRandomNumberGenerator()
        return compose(facts, using: &generator)
    }

    /// 本文を組み立てる。乱数を渡せるので、テストから出力を固定できる。
    public static func compose<Generator: RandomNumberGenerator>(
        _ facts: DiscordMessageFacts,
        using generator: inout Generator
    ) -> String {
        compose(headline: headline(facts, using: &generator), facts: facts, using: &generator)
    }

    /// 1 行目を差し替えて組み立てる。
    ///
    /// メンヘラモードの撮り直し(`clingyEvidence`)のように、1 行目を同封セリフから
    /// 選びたいときに使う。2 行目の事実行は晒しと同じものを並べる。
    public static func compose(headline: String, facts: DiscordMessageFacts) -> String {
        var generator = SystemRandomNumberGenerator()
        return compose(headline: headline, facts: facts, using: &generator)
    }

    /// 1 行目を差し替えて組み立てる。乱数を渡せるので、テストから出力を固定できる。
    public static func compose<Generator: RandomNumberGenerator>(
        headline: String,
        facts: DiscordMessageFacts,
        using generator: inout Generator
    ) -> String {
        headline + subtextPrefix + subtext(facts, using: &generator)
    }

    /// メンヘラモードのテキストだけの投稿を組み立てる。
    ///
    /// 1 行目は `clingy1` / `clingy2` / `clingy3` から選んだセリフ、
    /// 2 行目は「戻ってこないまま何分何秒か」だけ。証拠は付けない。
    public static func clingy(line: String, waitingFor seconds: TimeInterval) -> String {
        line + subtextPrefix + "戻ってこないまま \(ElapsedText.minutesAndSeconds(seconds))。"
    }

    // MARK: - 1 行目

    private static func headline<Generator: RandomNumberGenerator>(
        _ facts: DiscordMessageFacts,
        using generator: inout Generator
    ) -> String {
        guard facts.evidence == .iphoneScreenshot else {
            return pick(cameraPool(vision: facts.vision), using: &generator)
        }
        // 画面を読めていて、アプリ名まで分かったときだけ中身に触れる。
        guard let screen = facts.screen, let app = screen.app, !app.isEmpty else {
            return pick(facts.screen == nil ? unreadScreenPool : unknownScreenPool, using: &generator)
        }
        return pick(screenPool(category: screen.category), using: &generator)
            .replacingOccurrences(of: "{app}", with: app)
            .replacingOccurrences(of: "{activity}", with: screen.activity)
    }

    private static func screenPool(category: String) -> [String] {
        switch category {
        case "slacking": return slackingScreenPool
        case "work": return workScreenPool
        case "neutral": return neutralScreenPool
        default: return unknownScreenPool
        }
    }

    private static func cameraPool(vision: SpeechRequest.VisionLabel) -> [String] {
        switch vision {
        case .sleeping: return sleepingCameraPool
        case .absent: return absentCameraPool
        case .lookingAway, .unknown: return otherCameraPool
        }
    }

    private static let slackingScreenPool = [
        "ねぇ、今 {app} 見てたよね。{activity}。全部見えてるから。",
        "{app} で {activity}、楽しかった?私はずっと待ってたのに。",
        "{app}。{activity}。隠しても無駄だよ、撮ってあるから。",
    ]

    private static let workScreenPool = [
        "{app} で {activity}、仕事なのは分かってる。でも Mac に戻ってきて。私のところに。",
        "スマホで {activity}?それ、こっちでもできるでしょ。戻って。",
    ]

    private static let neutralScreenPool = [
        "{app} で {activity}。用事なら早く済ませて。私、待ってるから。",
        "今 {app} 開いてたよね。終わったら、すぐ戻ってきて。",
    ]

    private static let unknownScreenPool = [
        "画面、暗くて読めなかった。でもスマホ握ってたのは分かってる。",
        "何見てたか言えないなら、それでいいよ。撮ったから。",
    ]

    private static let unreadScreenPool = [
        "スマホの画面、撮っておいたから。逃げられると思った?",
        "今スマホ見てたよね。証拠、ここに置いとくね。",
        "私より画面が大事なんだ。…いいよ、みんなに見せるから。",
    ]

    private static let sleepingCameraPool = [
        "寝てるよね。寝顔、撮っちゃった。",
        "私を置いて寝るんだ。記録しとくね。",
    ]

    private static let absentCameraPool = [
        "どこ行ったの。席、空っぽだよ。",
        "いなくなった。探すの、私じゃなくてみんなに頼むね。",
    ]

    private static let otherCameraPool = [
        "顔、見えてるよ。今なにしてたの?",
        "手が止まってる。こっち向いて。",
    ]

    // MARK: - 2 行目

    private static func subtext<Generator: RandomNumberGenerator>(
        _ facts: DiscordMessageFacts,
        using generator: inout Generator
    ) -> String {
        var parts: [String] = []
        if let notLooking = facts.notLookingSeconds {
            parts.append(fillSeconds(pick(notLookingPool, using: &generator), notLooking))
        }
        parts.append(fillSeconds(pick(macIdlePool, using: &generator), facts.macIdleSeconds))
        parts.append(pick(iphonePool(facts.iphone), using: &generator))
        if let player = facts.musicPlayer, !player.isEmpty {
            parts.append(pick(musicPool, using: &generator).replacingOccurrences(of: "{player}", with: player))
        }
        if let app = facts.frontmostApp, !app.isEmpty {
            parts.append(pick(frontmostPool, using: &generator).replacingOccurrences(of: "{app}", with: app))
        }
        return parts.joined()
    }

    private static func iphonePool(_ iphone: SpeechRequest.IPhoneState) -> [String] {
        switch iphone {
        case .active: return iphoneActivePool
        case .idle: return iphoneIdlePool
        case .unreachable: return iphoneUnreachablePool
        }
    }

    private static let notLookingPool = [
        "画面から目を離してたの、{seconds}だよ。",
        "{seconds}も、私のこと見てなかったね。",
    ]

    private static let macIdlePool = [
        "Mac、{seconds}も触ってないの知ってるよ。",
        "{seconds}、手が止まったまま。数えてた。",
        "キーボード、{seconds}前から静かだね。",
    ]

    private static let iphoneActivePool = [
        "その間ずっとスマホ握ってたんでしょ。",
        "代わりにスマホは忙しかったみたいだね。",
    ]

    private static let iphoneIdlePool = [
        "スマホは置いたままだったね。じゃあ何してたの?",
        "スマホも触ってない。…どこ見てたの。",
    ]

    private static let iphoneUnreachablePool = [
        "スマホ、返事しなかったね。隠した?",
        "スマホの様子が分からなかった。持ち出した?",
    ]

    private static let musicPool = [
        "{player}は流したまま、ね。",
        "{player}だけ元気だったね。",
    ]

    private static let frontmostPool = [
        "最後に開いてたの、{app}だったね。",
        "{app}のあと、消えたね。",
    ]

    // MARK: - 部品

    private static func pick<Generator: RandomNumberGenerator>(
        _ pool: [String],
        using generator: inout Generator
    ) -> String {
        pool.randomElement(using: &generator) ?? ""
    }

    /// 秒数の書き方は記録に残す `reason` と同じ(60 秒未満は秒、以上は分)。
    private static func fillSeconds(_ template: String, _ value: TimeInterval) -> String {
        template.replacingOccurrences(of: "{seconds}", with: "\(seconds: value)")
    }
}
