import Foundation
import SwiftUI
import os

/// 検知で作らせたセリフと、あればその読み上げ用の音声。
///
/// 音声を取れた瞬間に鳴らすと、ペットが吹き出しを待たせているあいだに声だけ先に出てしまう。
/// 鳴らすのはペット側に任せ、ここでは文と音声を一緒に運ぶ。
public struct SpokenSpeech: Sendable, Equatable {
    /// 吹き出しに出す文。
    public let text: String
    /// 読み上げ用の音声(WAV)。作れていなければ `nil`。
    public let audio: Data?
    /// セリフを作るときに読み取れた iPhone の画面。読ませていなければ `nil`。
    /// Discord の文面に使う。
    public let screen: SpokenLine.ScreenReading?

    public init(text: String, audio: Data? = nil, screen: SpokenLine.ScreenReading? = nil) {
        self.text = text
        self.audio = audio
        self.screen = screen
    }
}

/// サボりを見張って、決まったことを実行する。
///
/// **状態機械そのものがこのアプリの仕様。**
/// 正常 → 疑い 1(Touch ID)→ 疑い 2(AirPods の首振り)→ 疑い 3(最終警告)→ 晒し →
/// メンヘラモード、と一方向に進み、Mac を触った時点でどこからでも正常に戻る。
///
/// **どのアクションが失敗しても評価ループは止めない。** カメラが使えない、
/// VOICEVOX が起動していない、Discord のトークンが無い、はどれも起こりうる。
/// 1 つ転んだせいで見張り自体が死ぬのが一番まずい。
@MainActor
public final class DetectionEngine: ObservableObject {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "detection")

    /// 何秒ごとに評価するか。
    public static let tickSeconds: TimeInterval = 5

    /// 画面に残す記録の件数。
    public static let logHistoryLimit = 50

    /// デバッグメニューの「メンヘラを始める」で続けて投げる回数。
    public static let debugClingyBurstCount = 5

    /// デバッグの連投の間隔。同封音声が 3〜4 秒なので、声が重ならない長さにする。
    public static let debugClingyBurstGapSeconds: TimeInterval = 5

    /// 同封セリフを読めなかったときに使う、疑い 2 の問いかけ。
    public static let fallbackQuestion = "ねぇ、まだそこにいる?"

    /// 同封セリフを読めなかったときに使う、メンヘラモードを終える一言。
    public static let fallbackReturnedLine = "やっと戻ってきた。"

    /// タイマーの待ち方。本番は `Task.sleep`、テストでは短時間で解決するものに差し替える。
    public typealias Sleeping = (Duration) async -> Void

    @Published public private(set) var isWatching = false
    @Published public private(set) var state: DetectionState = .normal
    @Published public private(set) var lastSignals: DetectionSignals?

    /// いま音楽が鳴っているか。
    @Published public private(set) var music: NowPlaying = .silent
    @Published public private(set) var log: [DetectionLogEntry] = []

    /// いまのエスカレーション段階。ペットへ渡している `PetEvent.escalationStage` と同じ値。
    /// 状態パネルに出して、どこまで上がっているかを見えるようにする。
    @Published public private(set) var escalationStage = 0

    /// 最後に証拠を撮った時刻。まだ撮っていなければ `nil`。
    @Published public private(set) var lastEvidenceAt: Date?
    @Published public var thresholds: DetectionThresholds = .default

    /// 休憩が明ける時刻。休憩していなければ `nil`。
    ///
    /// ここが埋まっている間は評価そのものを飛ばす。撮らず、送らず、喋らない。
    @Published public private(set) var breakUntil: Date?

    private let idleMonitor: MacIdleMonitor
    private let frontmostMonitor: FrontmostAppMonitor
    private let attendance: AttendanceModel?
    private let musicController: MusicControlling
    private let sleep: Sleeping
    private var loop: Task<Void, Never>?

    /// 走っているチェックの種類。走っていなければ `nil`。
    private enum RunningCheck { case touchID, headGesture }
    private var runningCheck: RunningCheck?

    /// Touch ID / 首振りのチェックが走っているか。返事を待っているあいだは段が進まない。
    public var isCheckRunning: Bool { runningCheck != nil }

    /// チェックの世代。畳んだら 1 つ進めて、遅れて届いた結果を捨てる。
    private var checkGeneration = 0

    /// いま出している疑い 2 の問いかけ。出していなければ `nil`。
    private var promptSession: SuspectPromptSession?

    /// いまの段の「チェック後の待ち」が始まった時刻。チェック中は `nil`。
    private var stageWaitingSince: Date?
    /// メンヘラモードで最後にテキストを投げた時刻。
    private var lastClingyPostAt: Date?
    /// メンヘラモードで最後に証拠を撮り直した時刻。
    private var lastClingyEvidenceAt: Date?

    /// デバッグの連投が走っているか。走っているあいだは評価を止める。
    private var clingyBurstInProgress = false

    /// デバッグから始めた確認が走っているか。
    ///
    /// メニューを押した操作そのものが Mac の入力なので、素通しだと次のティックで
    /// 「戻ってきた」と見なして数秒で畳んでしまう。走っているあいだは Mac の入力で畳まない。
    private var debugCheckInProgress = false

    /// 正常が続き始めた時刻。褒めるたびにここを now へ進める。続いていなければ `nil`。
    private var focusStreakSince: Date?

    /// 実行部。テストからはここを差し替えて、実際に撮らず送らずに筋道だけを確かめる。
    public struct Actions: Sendable {
        public var captureMacPhoto: @Sendable () async -> Data?
        public var captureIPhoneScreenshot: @Sendable () async -> Data?
        public var speak: @Sendable (SpeechRequest) async -> SpokenSpeech?
        /// iPhone の画面だけを読ませる。セリフも音声も作らせない。
        /// セリフを作れなかったときに、Discord の文面のためだけに呼ぶ。
        public var readScreen: @Sendable (SpeechRequest) async -> ScreenReadResult?
        public var interrupt: @Sendable (SpeechRequest) async -> Void
        /// Discord へ投稿する。引数は 本文 / 画像 / ファイル名 / メンションを付けるか。
        public var post: @Sendable (String, Data?, String, Bool) async -> Bool
        public var classify: @Sendable (Data) async -> SpeechRequest.VisionLabel
        /// 問いかけを出して AirPods の首振りを待つ。既定は「AirPods が無い」として即座に返す。
        public var askHeadGesture: @Sendable (String, TimeInterval) async -> HeadGestureResponse
        /// 疑い 1 の Touch ID チェック。引数は iPhone を触っているか(セリフの区分を選ぶのに使う)。
        /// カットインとセリフは配線側(`AppCoordinator`)が持つ。
        public var confirmPresence: @Sendable (Bool) async -> AttendanceStampOutcome
        /// 走っている Touch ID チェックを打ち切る。畳むときに呼ぶ。
        public var cancelPresenceCheck: @Sendable () async -> Void

        public init(
            captureMacPhoto: @escaping @Sendable () async -> Data? = { nil },
            captureIPhoneScreenshot: @escaping @Sendable () async -> Data? = { nil },
            speak: @escaping @Sendable (SpeechRequest) async -> SpokenSpeech? = { _ in nil },
            readScreen: @escaping @Sendable (SpeechRequest) async -> ScreenReadResult? = { _ in nil },
            interrupt: @escaping @Sendable (SpeechRequest) async -> Void = { _ in },
            post: @escaping @Sendable (String, Data?, String, Bool) async -> Bool = { _, _, _, _ in false },
            classify: @escaping @Sendable (Data) async -> SpeechRequest.VisionLabel = { _ in .unknown },
            askHeadGesture: @escaping @Sendable (String, TimeInterval) async -> HeadGestureResponse = {
                _,
                _ in .unavailable(reason: "未接続")
            },
            confirmPresence: @escaping @Sendable (Bool) async -> AttendanceStampOutcome = { _ in .unavailable },
            cancelPresenceCheck: @escaping @Sendable () async -> Void = {}
        ) {
            self.captureMacPhoto = captureMacPhoto
            self.captureIPhoneScreenshot = captureIPhoneScreenshot
            self.speak = speak
            self.readScreen = readScreen
            self.interrupt = interrupt
            self.post = post
            self.classify = classify
            self.askHeadGesture = askHeadGesture
            self.confirmPresence = confirmPresence
            self.cancelPresenceCheck = cancelPresenceCheck
        }
    }

    public var actions = Actions()

    /// iPhone の様子。SSE で流れてくる値を外から入れてもらう。
    public var iphoneState: SpeechRequest.IPhoneState = .unreachable

    /// iPhone で開いているアプリ名。SSE で流れてくる値を外から入れてもらう。操作中でなければ nil。
    public var iphoneForegroundApp: String? = nil

    /// 判定のたびにペットへ渡す通知口。
    /// エンジンはペットの中身を知らないので、渡す形だけ決めて外で繋ぐ。
    public var onEvent: ((PetEvent) -> Void)?

    /// 集中が続いたときの合図。`focusStreakIntervalSeconds` ごとに呼ぶ。
    public var onFocusStreak: (() -> Void)?

    /// 出している問いかけを引っ込めてもらう合図。
    /// はい / いいえ / 無反応 / エピソード終了、どの終わり方でも必ず呼ぶ。
    public var onPromptDismissed: (() -> Void)?

    public init(
        idleMonitor: MacIdleMonitor = MacIdleMonitor(),
        frontmostMonitor: FrontmostAppMonitor = FrontmostAppMonitor(),
        attendance: AttendanceModel? = nil,
        musicController: MusicControlling = AppleScriptMusicController(),
        sleep: @escaping Sleeping = { try? await Task.sleep(for: $0) }
    ) {
        self.idleMonitor = idleMonitor
        self.frontmostMonitor = frontmostMonitor
        self.attendance = attendance
        self.musicController = musicController
        self.sleep = sleep
    }

    public func start() {
        guard !isWatching else { return }
        isWatching = true
        // 監視を始めた瞬間から数え始める。
        focusStreakSince = Date()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.evaluate()
                try? await Task.sleep(for: .seconds(Self.tickSeconds))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        isWatching = false
        focusStreakSince = nil
        music = .silent
        // 見張りを止めたのに問いかけだけ画面に残しても、答えようがない。
        // 休憩(`breakUntil`)は消さない。休憩と監視の開始 / 停止は別の話。
        //
        // 疑い以上の途中で止めたなら、エピソードもここで終わらせる。
        // 黙って `state` だけ戻すと、ペットは固定アニメのまま取り残される。
        if state == .normal {
            dismissPrompt()
        } else {
            finishEpisode()
        }
    }

    /// いまの材料を集める。
    public func currentSignals(now: Date = Date()) async -> DetectionSignals {
        let idle = idleMonitor.idleSeconds()
        let music = await currentMusic(idleSeconds: idle)
        return DetectionSignals(
            macIdleSeconds: idle,
            iphone: iphoneState,
            iphoneForegroundApp: iphoneForegroundApp,
            music: music,
            secondsSinceStamp: attendance?.secondsSinceLastStamp,
            frontmostApp: frontmostMonitor.currentAppName()
        )
    }

    /// 音楽が鳴っているかを見に行く。
    ///
    /// AppleScript の問い合わせなので、手が動いている間は投げない。
    /// 何も起きない場面で他アプリに毎秒話しかける理由がない。
    private func currentMusic(idleSeconds: TimeInterval) async -> NowPlaying {
        guard idleSeconds >= thresholds.minimumIdleSeconds else {
            music = .silent
            return .silent
        }
        music = await musicController.nowPlaying()
        return music
    }

    // MARK: - 評価

    /// 1 回だけ評価して実行する。ループからも、画面の「いま評価する」ボタンからも呼ぶ。
    ///
    /// 休憩中はここで打ち切る。**材料を集める前に返す。**
    @discardableResult
    public func evaluate(now: Date = Date()) async -> DetectionDecision {
        if let resting = restingDecision(now: now) {
            if state != .normal { finishEpisode() }
            // 休んでいる時間は集中の続きではない。
            focusStreakSince = nil
            return resting
        }

        // デバッグの連投中。ここで畳むと投稿が途中で止まるので、終わるまで触らない。
        if clingyBurstInProgress { return .idle(reason: "メンヘラの連投中") }

        // デバッグから始めた確認中。メニューを押した手の動きで畳むと、
        // 出したばかりの問いかけやカットインが数秒で消える。決着するまで触らない。
        if debugCheckInProgress { return .idle(reason: "デバッグの確認中") }

        let signals = await currentSignals(now: now)
        lastSignals = signals

        // 何か入力があった。疑いの途中でも、メンヘラモードでもここで拾う。
        if signals.macIdleSeconds < thresholds.minimumIdleSeconds {
            return await handleReturn(signals: signals, now: now)
        }

        switch state {
        case .normal:
            return await advanceFromNormal(signals: signals, now: now)
        case .suspect(let stage):
            return await advanceSuspect(stage: stage, signals: signals, now: now)
        case .exposing:
            // 撮って送っている最中。次のティックまで触らない。
            return .idle(reason: "晒している最中")
        case .clingy(let since, let count):
            return await advanceClingy(since: since, count: count, signals: signals, now: now)
        }
    }

    /// 正常からの進み方。無操作が `suspectSeconds` を超えたら疑い 1 に入る。
    private func advanceFromNormal(signals: DetectionSignals, now: Date) async -> DetectionDecision {
        // 本人が指紋で「席にいる」と示した直後は疑わない。ここで疑い始めるとただの嫌がらせになる。
        if let sinceStamp = signals.secondsSinceStamp, sinceStamp < thresholds.stampGraceSeconds {
            advanceFocusStreak(now: now)
            return .idle(reason: "\(seconds: sinceStamp) 前に在席スタンプが押されている")
        }
        guard signals.macIdleSeconds >= thresholds.suspectSeconds else {
            advanceFocusStreak(now: now)
            return .idle(reason: "Mac が \(seconds: signals.macIdleSeconds) 無操作")
        }
        // 疑いに入ったら、集中は途切れたものとして数え直す。
        focusStreakSince = nil
        return enterSuspect(stage: DetectionState.firstSuspectStage, signals: signals, now: now)
    }

    /// 疑いの途中からの進み方。チェック中は待ち、待ちが明けたら次の段へ。
    private func advanceSuspect(
        stage: Int,
        signals: DetectionSignals,
        now: Date
    ) async -> DetectionDecision {
        guard runningCheck == nil else {
            return .idle(reason: "疑い \(stage) 回目・確認中")
        }
        guard let since = stageWaitingSince,
            now.timeIntervalSince(since) >= thresholds.stageIntervalSeconds
        else {
            return .idle(reason: "疑い \(stage) 回目・様子を見ている")
        }
        guard stage >= DetectionState.lastSuspectStage else {
            return enterSuspect(stage: stage + 1, signals: signals, now: now)
        }
        // 最終警告のあとも動かない。晒しに進む。
        let decision = DetectionDecision(
            state: .exposing,
            evidence: EvidenceKind.forEvidence(iphone: signals.iphone),
            reason: "最終警告のあとも Mac が \(seconds: signals.macIdleSeconds) 無操作"
        )
        state = .exposing
        await expose(decision, signals: signals, now: now)
        return decision
    }

    /// 何か入力があったときの畳み方。状態ごとに戻り方が違う。
    private func handleReturn(signals: DetectionSignals, now: Date) async -> DetectionDecision {
        switch state {
        case .normal:
            advanceFocusStreak(now: now)
            return .idle(reason: "Mac を \(seconds: signals.macIdleSeconds) 前まで触っている")
        case .exposing:
            // 撮って送っている最中に畳むと、投稿だけが宙に浮く。終わらせてから次のティックで拾う。
            return .idle(reason: "晒している最中")
        case .suspect(let stage):
            // 疑いの途中で戻ってきただけ。責める理由がないので黙って戻す。
            let decision = DetectionDecision(state: .normal, reason: "疑い \(stage) 回目の途中で戻ってきた")
            finishEpisode()
            // 戻ってきたこの瞬間から、集中が続いている時間を数え直す。
            advanceFocusStreak(now: now)
            record(decision, outcome: "黙って正常に戻す", at: now)
            return decision
        case .clingy(let since, _):
            let decision = await finishClingy(since: since, now: now)
            advanceFocusStreak(now: now)
            return decision
        }
    }

    // MARK: - 疑い

    /// 疑いの段に入る。1 なら Touch ID、2 なら首振り、3 は最終警告だけ。
    @discardableResult
    private func enterSuspect(stage: Int, signals: DetectionSignals, now: Date) -> DetectionDecision {
        cancelChecks()
        state = .suspect(stage: stage)
        stageWaitingSince = nil

        let decision = DetectionDecision(
            state: state,
            reason: "Mac が \(seconds: signals.macIdleSeconds) 無操作(疑い \(stage) 回目)"
        )

        switch stage {
        case 1:
            // ペットは待つ姿で固定するだけ。セリフとカットインは演出側が出す。
            notifyPet(line: "")
            startTouchIDCheck(onPhone: signals.isOnPhone)
            record(decision, outcome: "Touch ID で確かめる", at: now)
        case 2:
            startHeadGestureCheck(onPhone: signals.isOnPhone)
            record(decision, outcome: "首振りで確かめる", at: now)
        default:
            // 最終警告。ここではもう確かめない。次に動かなければ晒す。
            let spoken = bundledSpeech(for: signals.isOnPhone ? .finalWarnPhone : .finalWarn)
            notifyPet(line: spoken?.text ?? "", audio: spoken?.audio)
            stageWaitingSince = now
            record(decision, outcome: "最終警告を出した", at: now)
        }
        return decision
    }

    /// 疑い 1。在席スタンプと同じ演出で Touch ID を確かめる。
    ///
    /// 10 秒待つあいだも見張りは進むので、待ち合わせは別のタスクに投げる。
    /// 待っているあいだに Mac を触られたら、`cancelChecks()` が世代を進めて結果を捨てる。
    private func startTouchIDCheck(onPhone: Bool) {
        runningCheck = .touchID
        checkGeneration += 1
        let generation = checkGeneration
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.actions.confirmPresence(onPhone)
            self.finishTouchIDCheck(outcome: outcome, generation: generation)
        }
    }

    private func finishTouchIDCheck(outcome: AttendanceStampOutcome, generation: Int) {
        guard generation == checkGeneration, runningCheck == .touchID else { return }
        guard case .suspect(let stage) = state, stage == DetectionState.firstSuspectStage else { return }
        runningCheck = nil
        // 決着したので、ここから先は通常どおり Mac の入力で畳んでよい。
        debugCheckInProgress = false

        let now = Date()
        guard outcome != .stamped else {
            // 指を置いた本人を疑い続けない。**猶予は付けない**(メニューの在席スタンプだけが猶予を持つ)。
            let decision = DetectionDecision(state: .normal, reason: "疑い 1 回目・Touch ID で在席を確かめた")
            finishEpisode()
            record(decision, outcome: "正常に戻す(猶予なし)", at: now)
            return
        }
        // 空振り・時間切れ。セリフは演出側が出しているので、ここでは待ちに入るだけ。
        stageWaitingSince = now
        let decision = DetectionDecision(state: state, reason: "疑い 1 回目・Touch ID に応じなかった")
        record(decision, outcome: outcome == .timedOut ? "時間切れ" : "空振り", at: now)
    }

    /// 疑い 2。同封の質問を喋りつつ、はい / いいえ の問いかけを出して首振りを待つ。
    ///
    /// 答えは 3 か所から来る(ボタン・首振り・無反応タイマー)が、採用するのは先に来た 1 つだけ。
    private func startHeadGestureCheck(onPhone: Bool) {
        runningCheck = .headGesture
        checkGeneration += 1
        let generation = checkGeneration

        let picked = BundledVoiceLines.shared.pick(onPhone ? .askQuestionPhone : .askQuestion)
        let question = picked?.text ?? Self.fallbackQuestion

        let session = SuspectPromptSession()
        promptSession = session
        let id = session.id

        session.waitForHeadGesture(
            question: question,
            timeout: thresholds.promptTimeoutSeconds,
            ask: actions.askHeadGesture,
            onAnswer: { [weak self] sessionID, answer in
                self?.resolvePrompt(sessionID: sessionID, answer: answer, generation: generation)
            }
        )
        session.startTimeout(
            seconds: thresholds.promptTimeoutSeconds,
            sleep: sleep,
            onTimeout: { [weak self] sessionID in
                self?.resolvePrompt(sessionID: sessionID, answer: nil, generation: generation)
            }
        )

        let prompt = PetYesNoPrompt(question: question, audio: picked?.audio) { [weak self] answer in
            Task { @MainActor in
                self?.resolvePrompt(sessionID: id, answer: answer, generation: generation)
            }
        }
        notifyPet(line: "", prompt: prompt)
    }

    /// 問いかけの決着。`answer` が `nil` なら時間切れ。
    ///
    /// **首を縦に振ったのか横に振ったのかをセリフで必ず言う。**
    /// どちらに取られたか分からないまま段が進むのが一番困る。
    private func resolvePrompt(sessionID: UUID, answer: Bool?, generation: Int) {
        guard let session = promptSession, session.claim(sessionID: sessionID) else { return }
        promptSession = nil
        session.settle()
        onPromptDismissed?()

        guard generation == checkGeneration, runningCheck == .headGesture else { return }
        guard case .suspect(let stage) = state, stage == 2 else { return }
        runningCheck = nil
        // 決着したので、ここから先は通常どおり Mac の入力で畳んでよい。
        debugCheckInProgress = false

        let now = Date()
        guard answer != true else {
            let spoken = bundledSpeech(for: .gestureYes)
            let decision = DetectionDecision(state: .normal, reason: "疑い 2 回目・うなずいた")
            finishEpisode(line: spoken?.text ?? "", audio: spoken?.audio)
            record(decision, outcome: "正常に戻す", at: now)
            return
        }
        let spoken = bundledSpeech(for: answer == nil ? .askTimeout : .gestureNo)
        stageWaitingSince = now
        notifyPet(line: spoken?.text ?? "", audio: spoken?.audio)
        let decision = DetectionDecision(
            state: state,
            reason: answer == nil ? "疑い 2 回目・返事が無かった" : "疑い 2 回目・首を横に振った"
        )
        record(decision, outcome: "様子を見る", at: now)
    }

    // MARK: - 晒し

    /// 証拠を撮って Discord へ送る。成功しても失敗してもメンヘラモードに入る。
    private func expose(_ decision: DetectionDecision, signals: DetectionSignals, now: Date) async {
        var notes: [String] = []

        let kind = decision.evidence
        let data = await collectEvidence(kind)
        if data == nil {
            notes.append("証拠を取れなかった")
        } else {
            lastEvidenceAt = now
            notes.append("証拠を取った")
        }

        // 写真に写っているのが「寝ている/よそ見/不在」のどれかを見立てる。
        // 判定には使わず、セリフと Discord の文面に添えるだけ。
        var label = SpeechRequest.VisionLabel.unknown
        if let data, kind == .macCamera {
            label = await actions.classify(data)
        }
        // iPhone の画面を撮ったときだけ、その PNG を添えて「何をしているか」まで読ませる。
        // Mac のカメラ写真には顔しか写らないので送らない(読ませても何も出てこない)。
        let screenshot = kind == .iphoneScreenshot ? data : nil
        let request = makeRequest(signals: signals, label: label, screenshot: screenshot)

        // 画面を撮れたときは、その中身に触れたセリフを作らせる。作れなければ同封セリフに倒す。
        var spoken: SpokenSpeech?
        if screenshot != nil { spoken = await actions.speak(request) }
        var screen = spoken?.screen
        if spoken == nil {
            spoken = bundledSpeech(
                for: BundledVoiceKind.forDetection(vision: label, iphone: signals.iphone, escalation: .expose)
            )
            // 喋れなくても、Discord の文面のためだけに画面を読ませる。
            if screenshot != nil { screen = await actions.readScreen(request)?.screen }
        }
        notifyPet(line: spoken?.text ?? "", audio: spoken?.audio, label: label)

        // 止める音楽が無いのに画面を覆っても空振りするだけ。鳴っているときだけ画面を奪う。
        if signals.music.isPlaying {
            await actions.interrupt(request)
            notes.append("音楽を止めて聞かせた")
        }

        if let data {
            let facts = discordFacts(evidence: kind, signals: signals, label: label, screen: screen)
            let sent = await actions.post(
                DiscordMessageComposer.compose(facts),
                data,
                kind.filename,
                true
            )
            notes.append(sent ? "Discord に送った" : "Discord に送れなかった")
        }

        record(decision, outcome: notes.joined(separator: " / "), at: now)
        enterClingy(now: now)
    }

    // MARK: - メンヘラモード

    /// メンヘラモードに入る。証拠はいま撮ったばかりなので、次の投稿は間隔ぶん先。
    func enterClingy(now: Date) {
        state = .clingy(since: now, count: 0)
        lastClingyPostAt = now
        lastClingyEvidenceAt = now
        notifyPet(line: "")
    }

    /// メンヘラモードの 1 ティック。間隔が来ていれば Discord へ投げる。
    private func advanceClingy(
        since: Date,
        count: Int,
        signals: DetectionSignals,
        now: Date
    ) async -> DetectionDecision {
        guard let lastPost = lastClingyPostAt,
            now.timeIntervalSince(lastPost) >= thresholds.clingyIntervalSeconds
        else {
            return .idle(reason: "メンヘラモード(\(count) 回目)")
        }

        // 撮り直しの番なら、テキストだけの投稿とは重ねず証拠つき 1 件にまとめる。
        let withEvidence =
            lastClingyEvidenceAt.map {
                now.timeIntervalSince($0) >= thresholds.clingyEvidenceIntervalSeconds
            } ?? true

        return await postClingy(
            since: since,
            count: count,
            signals: signals,
            now: now,
            withEvidence: withEvidence
        )
    }

    /// メンヘラの 1 件を実際に投げる。間隔を計るのは呼ぶ側の仕事。
    @discardableResult
    private func postClingy(
        since: Date,
        count: Int,
        signals: DetectionSignals,
        now: Date,
        withEvidence: Bool
    ) async -> DetectionDecision {
        // 送る前に数えておく。送信を待っているあいだの次のティックで二重に投げないため。
        state = .clingy(since: since, count: count + 1)
        lastClingyPostAt = now
        if withEvidence { lastClingyEvidenceAt = now }

        let waiting = now.timeIntervalSince(since)
        let kind: BundledVoiceKind = withEvidence ? .clingyEvidence : Self.clingyKind(count: count)
        let spoken = bundledSpeech(for: kind)
        let evidence = withEvidence ? EvidenceKind.forEvidence(iphone: signals.iphone) : .none
        let decision = DetectionDecision(
            state: state,
            evidence: evidence,
            reason: "戻ってこないまま \(ElapsedText.minutesAndSeconds(waiting))(\(count + 1) 回目)"
        )

        var notes: [String] = []
        var data: Data?
        var label = SpeechRequest.VisionLabel.unknown
        if withEvidence {
            data = await collectEvidence(evidence)
            if let data {
                lastEvidenceAt = now
                notes.append("証拠を撮り直した")
                if evidence == .macCamera { label = await actions.classify(data) }
            } else {
                notes.append("証拠を取れなかった")
            }
        }

        notifyPet(line: spoken?.text ?? "", audio: spoken?.audio, label: label)

        let text = spoken?.text ?? Self.fallbackReturnedLine
        let body: String
        if withEvidence {
            let screenshot = evidence == .iphoneScreenshot ? data : nil
            let request = makeRequest(signals: signals, label: label, screenshot: screenshot)
            let screen = screenshot == nil ? nil : await actions.readScreen(request)?.screen
            body = DiscordMessageComposer.compose(
                headline: text,
                facts: discordFacts(evidence: evidence, signals: signals, label: label, screen: screen)
            )
        } else {
            body = DiscordMessageComposer.clingy(line: text, waitingFor: waiting)
        }
        let sent = await actions.post(body, data, evidence.filename, true)
        notes.append(sent ? "Discord に送った" : "Discord に送れなかった")

        record(decision, outcome: notes.joined(separator: " / "), at: now)
        return decision
    }

    /// 何回目かでメンヘラの言い方を変える。1〜2 回目 / 3〜5 回目 / 6 回目以降。
    private static func clingyKind(count: Int) -> BundledVoiceKind {
        switch count {
        case 0, 1: return .clingy1
        case 2, 3, 4: return .clingy2
        default: return .clingy3
        }
    }

    /// メンヘラモードを終える。**メンションは付けない。** 戻ってきた本人を呼びつける必要はない。
    @discardableResult
    private func finishClingy(since: Date, now: Date) async -> DetectionDecision {
        let spoken = bundledSpeech(for: .returned)
        let text = spoken?.text ?? Self.fallbackReturnedLine
        let decision = DetectionDecision(
            state: .normal,
            reason: "\(ElapsedText.minutesAndSeconds(now.timeIntervalSince(since))) ぶりに戻ってきた"
        )
        // 送る前に畳む。送信を待っているあいだの次のティックで二重に投げないため。
        finishEpisode(line: text, audio: spoken?.audio)
        let sent = await actions.post(text, nil, EvidenceKind.none.filename, false)
        record(decision, outcome: sent ? "Discord に送った(メンションなし)" : "Discord に送れなかった", at: now)
        return decision
    }

    // MARK: - 休憩

    /// 休憩に入る。明けるまで評価そのものを飛ばす。
    ///
    /// 監視を止めるのとは別物。ループは回り続けるが、`evaluate` が何もせずに返るだけ。
    /// 休憩が明ければ何もしなくても通常の評価に戻る。
    public func startBreak(now: Date = Date()) {
        breakUntil = now.addingTimeInterval(thresholds.breakDurationSeconds)
        focusStreakSince = nil
        if state == .normal {
            dismissPrompt()
        } else {
            finishEpisode()
        }
        onEvent?(
            PetEvent(state: .normal, escalationStage: 0, line: "\(breakMinutes) 分だけ、待ってる。")
        )
    }

    /// 休憩を切り上げる。
    public func endBreak() {
        breakUntil = nil
    }

    /// 「いま席にいる」と外から示された。疑いを畳んで正常に戻す。**Discord には何も送らない。**
    ///
    /// メニューの在席スタンプから呼ぶ。猶予(`stampGraceSeconds`)は在席の記録側が持つ。
    public func acknowledgePresence() {
        guard state != .normal else { return }
        finishEpisode()
    }

    /// 休憩の残り分数。表示用なので 1 分未満でも 0 分とは言わない。
    private var breakMinutes: Int {
        max(1, Int((thresholds.breakDurationSeconds / 60).rounded()))
    }

    /// 休憩中なら「何もしない」結論を返す。明けていれば片付けて `nil` を返し、通常の評価に戻す。
    private func restingDecision(now: Date) -> DetectionDecision? {
        guard let breakUntil else { return nil }
        guard now < breakUntil else {
            self.breakUntil = nil
            record(.idle(reason: "休憩が明けた"), outcome: "見張りに戻る", at: now)
            return nil
        }
        return .idle(reason: "休憩中(残り \(seconds: breakUntil.timeIntervalSince(now)))")
    }

    // MARK: - 集中継続

    /// 正常が続いている時間を進め、間隔ぶん経っていれば褒めてもらう。
    ///
    /// 数え始めるのは監視を始めた瞬間。疑い以上・休憩・監視停止でいったん忘れる。
    private func advanceFocusStreak(now: Date) {
        guard let since = focusStreakSince else {
            focusStreakSince = now
            return
        }
        guard now.timeIntervalSince(since) >= thresholds.focusStreakIntervalSeconds else { return }
        focusStreakSince = now
        onFocusStreak?()
    }

    // MARK: - 畳む

    /// 疑いのエピソードを終わらせて正常に戻す。走っているチェックも問いかけも畳む。
    private func finishEpisode(line: String = "", audio: Data? = nil) {
        cancelChecks()
        state = .normal
        stageWaitingSince = nil
        lastClingyPostAt = nil
        lastClingyEvidenceAt = nil
        escalationStage = 0
        onEvent?(PetEvent(state: .normal, escalationStage: 0, line: line, audio: audio))
    }

    /// 走っているチェックを打ち切る。遅れて届く結果は世代で弾く。
    private func cancelChecks() {
        checkGeneration += 1
        let wasTouchID = runningCheck == .touchID
        runningCheck = nil
        // 打ち切るならデバッグの確認も終わり。停止・休憩・エピソード終了はすべてここを通る。
        debugCheckInProgress = false
        dismissPrompt()
        guard wasTouchID else { return }
        // Touch ID のダイアログとカットインを閉じてもらう。
        Task { [actions] in await actions.cancelPresenceCheck() }
    }

    /// 問いかけを引っ込める。答えは採らない(＝見張りは続く)。
    private func dismissPrompt() {
        guard let session = promptSession else { return }
        promptSession = nil
        session.settle()
        onPromptDismissed?()
    }

    // MARK: - デバッグ

    /// デバッグメニューの「実際に進める」。**本物の遷移・撮影・投稿が走る。**
    public func runDebugStep(_ step: DetectionDebugStep) {
        Task { [weak self] in await self?.performDebugStep(step) }
    }

    private func performDebugStep(_ step: DetectionDebugStep) async {
        let now = Date()
        let signals = await currentSignals(now: now)
        lastSignals = signals
        focusStreakSince = nil

        switch step {
        case .touchIDCheck:
            // フラグは `enterSuspect` のあとに立てる。中の `cancelChecks()` が先に消してしまう。
            enterSuspect(stage: 1, signals: signals, now: now)
            debugCheckInProgress = true
        case .headGestureCheck:
            enterSuspect(stage: 2, signals: signals, now: now)
            debugCheckInProgress = true
        case .finalWarning:
            enterSuspect(stage: 3, signals: signals, now: now)
        case .expose:
            let decision = DetectionDecision(
                state: .exposing,
                evidence: EvidenceKind.forEvidence(iphone: signals.iphone),
                reason: "デバッグメニューから晒した"
            )
            state = .exposing
            await expose(decision, signals: signals, now: now)
        case .startClingy:
            cancelChecks()
            enterClingy(now: now)
            record(
                DetectionDecision(state: state, reason: "デバッグメニューからメンヘラモードに入った"),
                outcome: "\(Self.debugClingyBurstCount) 回ぶん続けて投げる",
                at: now
            )
            // 押したら確定で連投する。間隔待ちも「戻ってきた」判定も挟ませない。
            clingyBurstInProgress = true
            defer { clingyBurstInProgress = false }
            for round in 0..<Self.debugClingyBurstCount {
                // 途中で「メンヘラを終える」や停止で畳まれたら、そこで止める。
                guard case .clingy(let since, let count) = state else { break }
                await postClingy(
                    since: since,
                    count: count,
                    signals: signals,
                    now: Date(),
                    withEvidence: false
                )
                // 声が重ならないように間を空ける。最後の 1 件のあとは待たない。
                if round < Self.debugClingyBurstCount - 1 {
                    await sleep(.seconds(Self.debugClingyBurstGapSeconds))
                }
            }
        case .endClingy:
            guard case .clingy(let since, _) = state else {
                finishEpisode()
                return
            }
            await finishClingy(since: since, now: now)
        }
    }

    // MARK: - 実行の部品

    /// 同封音声から 1 本選ぶ。読めなければ `nil`。
    ///
    /// 疑い以降のセリフはすべて同封音声。bridge が落ちていても喋れる。
    private func bundledSpeech(for kind: BundledVoiceKind) -> SpokenSpeech? {
        guard let picked = BundledVoiceLines.shared.pick(kind) else { return nil }
        return SpokenSpeech(text: picked.text, audio: picked.audio)
    }

    private func collectEvidence(_ kind: EvidenceKind) async -> Data? {
        switch kind {
        case .macCamera: return await actions.captureMacPhoto()
        case .iphoneScreenshot: return await actions.captureIPhoneScreenshot()
        case .none: return nil
        }
    }

    /// Discord の文面の材料。
    private func discordFacts(
        evidence: EvidenceKind,
        signals: DetectionSignals,
        label: SpeechRequest.VisionLabel,
        screen: SpokenLine.ScreenReading?
    ) -> DiscordMessageFacts {
        DiscordMessageFacts(
            evidence: evidence,
            vision: label,
            iphone: signals.iphone,
            screen: screen,
            macIdleSeconds: signals.macIdleSeconds,
            musicPlayer: signals.music.playerName,
            frontmostApp: signals.frontmostApp
        )
    }

    /// ペットに状態とセリフを渡す。ペット側の実装は知らない。
    private func notifyPet(
        line: String,
        audio: Data? = nil,
        label: SpeechRequest.VisionLabel = .unknown,
        prompt: PetYesNoPrompt? = nil
    ) {
        escalationStage = state.escalationStage
        onEvent?(
            PetEvent(
                state: Self.petState(state),
                escalationStage: escalationStage,
                line: line,
                audio: audio,
                visionLabel: Self.petLabel(label),
                prompt: prompt
            )
        )
    }

    /// 新しい状態機械を、ペット側の 3 段の見た目に写す。
    private static func petState(_ state: DetectionState) -> SaboriState {
        switch state {
        case .normal: return .normal
        case .suspect: return .suspected
        case .exposing, .clingy: return .confirmed
        }
    }

    private static func petLabel(_ label: SpeechRequest.VisionLabel) -> VisionLabel {
        switch label {
        case .sleeping: return .asleep
        case .lookingAway: return .lookingAway
        case .absent: return .absent
        case .unknown: return .none
        }
    }

    private func makeRequest(
        signals: DetectionSignals,
        label: SpeechRequest.VisionLabel,
        screenshot: Data?
    ) -> SpeechRequest {
        SpeechRequest(
            idleSeconds: Int(signals.macIdleSeconds),
            escalation: .expose,
            frontmostApp: signals.frontmostApp,
            iphone: signals.iphone,
            iphoneApp: signals.iphoneForegroundApp,
            vision: label,
            screenshotPNG: screenshot
        )
    }

    private func record(_ decision: DetectionDecision, outcome: String, at now: Date) {
        Self.logger.info(
            "\(decision.state.key, privacy: .public): \(decision.reason, privacy: .public) → \(outcome, privacy: .public)"
        )
        log.insert(
            DetectionLogEntry(
                at: now,
                state: decision.state,
                evidence: decision.evidence,
                reason: decision.reason,
                outcome: outcome
            ),
            at: 0
        )
        if log.count > Self.logHistoryLimit {
            log.removeLast(log.count - Self.logHistoryLimit)
        }
    }
}
