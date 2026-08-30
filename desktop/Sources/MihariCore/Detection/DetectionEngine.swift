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

    public init(text: String, audio: Data? = nil) {
        self.text = text
        self.audio = audio
    }
}

/// サボりを見張って、決まったことを実行する。
///
/// 判定そのものは `DetectionJudge`(純粋関数)が持つ。ここがやるのは
/// 材料を集めて渡し、返ってきた結論どおりに撮る・喋る・送るところまで。
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

    /// 疑いに入ったときにペットが投げる問いかけ。
    public static let breakQuestion = "休憩中?"

    /// タイマーの待ち方。本番は `Task.sleep`、テストでは短時間で解決するものに差し替える。
    public typealias Sleeping = (Duration) async -> Void

    @Published public private(set) var isWatching = false
    @Published public private(set) var state: DetectionState = .normal
    @Published public private(set) var lastSignals: DetectionSignals?
    /// いまの視線の状況。画面に出して閾値の調整に使う。
    @Published public private(set) var gaze: GazeObservation = .none

    /// いま音楽が鳴っているか。
    @Published public private(set) var music: NowPlaying = .silent
    @Published public private(set) var log: [DetectionLogEntry] = []

    /// いまのエスカレーション段階。ペットへ渡している `PetEvent.escalationStage` と同じ値。
    /// 状態パネルに出して、どこまで上がっているかを見えるようにする。
    @Published public private(set) var escalationStage = 0

    /// 最後に証拠を撮った時刻。まだ撮っていなければ `nil`。
    /// クールダウンの判定に使っている値そのもので、残り時間の表示にも使う。
    @Published public private(set) var lastEvidenceAt: Date?
    @Published public var thresholds: DetectionThresholds = .default

    /// 休憩が明ける時刻。休憩していなければ `nil`。
    ///
    /// ここが埋まっている間は評価そのものを飛ばす。カメラも開かず、撮らず、送らず、喋らない。
    @Published public private(set) var breakUntil: Date?

    private let idleMonitor: MacIdleMonitor
    private let frontmostMonitor: FrontmostAppMonitor
    private let capture: CaptureService
    private let attendance: AttendanceModel?
    private var loop: Task<Void, Never>?
    private let gazeMonitor: GazeMonitor
    private let musicController: MusicControlling
    private let sleep: Sleeping
    /// いま出している「休憩中?」の問いかけ。出していなければ `nil`。
    private var promptSession: BreakPromptSession?

    /// 実行部。テストからはここを差し替えて、実際に撮らず送らずに筋道だけを確かめる。
    public struct Actions: Sendable {
        public var captureMacPhoto: @Sendable () async -> Data?
        public var captureIPhoneScreenshot: @Sendable () async -> Data?
        public var speak: @Sendable (SpeechRequest) async -> SpokenSpeech?
        public var interrupt: @Sendable (SpeechRequest) async -> Void
        public var post: @Sendable (String, Data?, String) async -> Bool
        public var classify: @Sendable (Data) async -> SpeechRequest.VisionLabel
        /// 問いかけを出して AirPods の首振りを待つ。既定は「AirPods が無い」として即座に返す。
        public var askHeadGesture: @Sendable (String, TimeInterval) async -> HeadGestureResponse

        public init(
            captureMacPhoto: @escaping @Sendable () async -> Data? = { nil },
            captureIPhoneScreenshot: @escaping @Sendable () async -> Data? = { nil },
            speak: @escaping @Sendable (SpeechRequest) async -> SpokenSpeech? = { _ in nil },
            interrupt: @escaping @Sendable (SpeechRequest) async -> Void = { _ in },
            post: @escaping @Sendable (String, Data?, String) async -> Bool = { _, _, _ in false },
            classify: @escaping @Sendable (Data) async -> SpeechRequest.VisionLabel = { _ in .unknown },
            askHeadGesture: @escaping @Sendable (String, TimeInterval) async -> HeadGestureResponse = {
                _,
                _ in .unavailable(reason: "未接続")
            }
        ) {
            self.captureMacPhoto = captureMacPhoto
            self.captureIPhoneScreenshot = captureIPhoneScreenshot
            self.speak = speak
            self.interrupt = interrupt
            self.post = post
            self.classify = classify
            self.askHeadGesture = askHeadGesture
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

    /// 出している問いかけを引っ込めてもらう合図。
    /// はい / いいえ / 無反応 / エピソード終了、どの終わり方でも必ず呼ぶ。
    public var onPromptDismissed: (() -> Void)?

    public init(
        idleMonitor: MacIdleMonitor = MacIdleMonitor(),
        frontmostMonitor: FrontmostAppMonitor = FrontmostAppMonitor(),
        capture: CaptureService = CaptureService(),
        attendance: AttendanceModel? = nil,
        gazeMonitor: GazeMonitor = GazeMonitor(),
        musicController: MusicControlling = AppleScriptMusicController(),
        sleep: @escaping Sleeping = { try? await Task.sleep(for: $0) }
    ) {
        self.idleMonitor = idleMonitor
        self.frontmostMonitor = frontmostMonitor
        self.capture = capture
        self.attendance = attendance
        self.gazeMonitor = gazeMonitor
        self.musicController = musicController
        self.sleep = sleep
    }

    public func start() {
        guard !isWatching else { return }
        isWatching = true
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
        let previous = state
        state = .normal
        gazeMonitor.stop()
        gaze = .none
        music = .silent
        // 見張りを止めたのに問いかけだけ画面に残しても、答えようがない。
        // 休憩(`breakUntil`)は消さない。休憩と監視の開始 / 停止は別の話。
        //
        // 疑い / 確定の途中で止めたなら、エピソードもここで終わらせる。
        // 黙って `state` だけ戻すと、ペットは固定アニメのまま取り残される
        // (再開後の評価は正常 → 正常で、解除のイベントが出ない)。
        if previous == .normal {
            dismissPrompt()
        } else {
            finishEpisode()
        }
    }

    /// いまの材料を集める。必要なら途中でカメラを覗く。
    public func currentSignals(now: Date = Date()) async -> DetectionSignals {
        let idle = idleMonitor.idleSeconds()
        let gaze = updateGazeMonitoring(idleSeconds: idle, now: now)
        let music = await currentMusic(idleSeconds: idle)
        return DetectionSignals(
            macIdleSeconds: idle,
            iphone: iphoneState,
            iphoneForegroundApp: iphoneForegroundApp,
            gaze: gaze,
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

    /// 視線の監視を、無操作かどうかで開け閉めする。
    ///
    /// **手を動かしている間はカメラを開けない。** 怪しくなってから開き、
    /// 触り始めたら閉じて、覚えていた結果も捨てる。
    private func updateGazeMonitoring(idleSeconds: TimeInterval, now: Date) -> GazeObservation {
        guard idleSeconds >= thresholds.gazeWatchSeconds else {
            if gazeMonitor.isRunning { gazeMonitor.stop() }
            gaze = .none
            return .none
        }

        if !gazeMonitor.isRunning { gazeMonitor.start() }

        let observed = gazeMonitor.observation
        // カメラを止めた直後の古い値で判定しない。
        gaze = observed.isFresh(now: now, within: thresholds.gazeFreshnessSeconds) ? observed : .none
        return gaze
    }

    /// 1 回だけ評価して実行する。ループからも、画面の「いま評価する」ボタンからも呼ぶ。
    ///
    /// 休憩中はここで打ち切る。**材料を集める前に返すので、カメラも開かない。**
    @discardableResult
    public func evaluate(now: Date = Date()) async -> DetectionDecision {
        if let resting = restingDecision(now: now) {
            state = .normal
            return resting
        }

        let signals = await currentSignals(now: now)
        lastSignals = signals

        let judge = DetectionJudge(thresholds: thresholds)
        let decision = judge.decide(
            signals,
            secondsSinceLastEvidence: lastEvidenceAt.map { now.timeIntervalSince($0) }
        )
        let previous = state
        state = decision.state

        guard decision.state != .normal else {
            if previous != .normal { finishEpisode() }
            return decision
        }

        // 疑いに入った瞬間だけ問いかけを添える。同じエピソードの中では二度と出さない。
        let prompt = previous == .normal && decision.state == .suspected ? makeBreakPrompt() : nil
        let outcome = await perform(decision, signals: signals, now: now, prompt: prompt)
        record(decision, outcome: outcome, at: now)
        return decision
    }

    // MARK: - 休憩

    /// 休憩に入る。明けるまで評価そのものを飛ばす。
    ///
    /// 監視を止めるのとは別物。ループは回り続けるが、`evaluate` が何もせずに返るだけ。
    /// 休憩が明ければ何もしなくても通常の評価に戻る。
    public func startBreak(now: Date = Date()) {
        breakUntil = now.addingTimeInterval(thresholds.breakDurationSeconds)
        escalationStage = 0
        // 休むと言った相手のカメラを開けたままにしない。緑ランプを点けておく理由がない。
        gazeMonitor.stop()
        gaze = .none
        onEvent?(
            PetEvent(state: .normal, escalationStage: 0, line: "\(breakMinutes) 分休むね")
        )
    }

    /// 休憩を切り上げる。
    public func endBreak() {
        breakUntil = nil
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

    // MARK: - 問いかけ

    /// 「休憩中?」の問いかけを組み立て、首振りと無反応タイマーの受け口も張る。
    ///
    /// ボタン・首振り・時間切れのどれが先に来ても、採用されるのは 1 つだけ
    /// (`BreakPromptSession` が保証する)。
    private func makeBreakPrompt() -> PetYesNoPrompt {
        dismissPrompt()

        let session = BreakPromptSession()
        promptSession = session
        let id = session.id

        session.waitForHeadGesture(
            question: Self.breakQuestion,
            timeout: thresholds.promptTimeoutSeconds,
            ask: actions.askHeadGesture,
            onAnswer: { [weak self] sessionID, answer in
                self?.resolvePrompt(sessionID: sessionID, answer: answer)
            }
        )
        session.startTimeout(
            seconds: thresholds.promptTimeoutSeconds,
            sleep: sleep,
            onTimeout: { [weak self] sessionID in
                self?.dismissPrompt(sessionID: sessionID)
            }
        )

        return PetYesNoPrompt(question: Self.breakQuestion) { [weak self] answer in
            Task { @MainActor in
                self?.resolvePrompt(sessionID: id, answer: answer)
            }
        }
    }

    /// 問いかけに答えが出た。**先に来た 1 つだけ**を採用し、残りは捨てる。
    private func resolvePrompt(sessionID: UUID, answer: Bool) {
        guard let session = promptSession, session.claim(sessionID: sessionID) else { return }
        promptSession = nil
        session.settle()
        onPromptDismissed?()
        if answer { startBreak() }
    }

    /// 問いかけを引っ込める。答えは採らない(＝監視を続ける)。
    ///
    /// - Parameter sessionID: 指定すると、その問いかけが出たままのときだけ引っ込める。
    ///   `nil` なら出ているものを無条件に引っ込める。
    private func dismissPrompt(sessionID: UUID? = nil) {
        guard let session = promptSession else { return }
        if let sessionID, session.id != sessionID { return }
        promptSession = nil
        session.settle()
        onPromptDismissed?()
    }

    /// 疑いのエピソードが終わった。答えの出ていない問いかけを閉じ、ペットに戻ったことを伝える。
    private func finishEpisode() {
        dismissPrompt()
        escalationStage = 0
        // セリフは空。「おかえり」の動きだけしてもらう。
        onEvent?(PetEvent(state: .normal, escalationStage: 0, line: ""))
    }

    // MARK: - 実行

    private func perform(
        _ decision: DetectionDecision,
        signals: DetectionSignals,
        now: Date,
        prompt: PetYesNoPrompt?
    ) async -> String {
        var notes: [String] = []

        let evidence = await collectEvidence(decision.evidence)
        if decision.evidence != .none {
            // クールダウンを始めるのは撮れたときだけ。失敗でも始めてしまうと、
            // tunneld が不調なだけで 3 分間何も撮らないまま過ぎる。
            if evidence == nil {
                notes.append("証拠を取れなかった(次の評価で撮り直す)")
            } else {
                lastEvidenceAt = now
                notes.append("証拠を取った")
            }
        }

        var label = SpeechRequest.VisionLabel.unknown
        if let evidence, decision.evidence == .macCamera {
            // 写真に写っているのが「寝ている/よそ見/不在」のどれかを見立てる。
            // 判定そのものには使わず、セリフと Discord の文面に添えるだけ。
            label = await actions.classify(evidence)
        }
        // iPhone の画面を撮ったときだけ、その PNG を添えて「何をしているか」まで読ませる。
        // Mac のカメラ写真には顔しか写らないので送らない(読ませても何も出てこない)。
        let screenshot = decision.evidence == .iphoneScreenshot ? evidence : nil
        let request = makeRequest(
            signals: signals,
            decision: decision,
            label: label,
            screenshot: screenshot
        )

        var line = ""
        // 音声は鳴らさずに持ち回る。ペットが吹き出しを出す瞬間に、そこで鳴らしてもらう。
        var audio: Data?
        if decision.shouldInterrupt {
            await actions.interrupt(request)
            line = decision.reason
            notes.append("音楽を止めて聞かせた")
        } else if decision.shouldSpeak {
            if let spoken = await actions.speak(request) {
                line = spoken.text
                audio = spoken.audio
            } else {
                line = decision.reason
                notes.append("喋れなかった")
            }
        }
        notifyPet(decision, label: label, line: line, audio: audio, prompt: prompt)

        if let evidence {
            let sent = await actions.post(decision.reason, evidence, filename(for: decision.evidence))
            notes.append(sent ? "Discord に送った" : "Discord に送れなかった")
        }

        return notes.isEmpty ? "声をかけた" : notes.joined(separator: " / ")
    }

    /// ペットに状態とセリフを渡す。ペット側の実装は知らない。
    private func notifyPet(
        _ decision: DetectionDecision,
        label: SpeechRequest.VisionLabel,
        line: String,
        audio: Data?,
        prompt: PetYesNoPrompt?
    ) {
        escalationStage = petStage(decision)
        onEvent?(
            PetEvent(
                state: petState(decision.state),
                escalationStage: escalationStage,
                line: line,
                audio: audio,
                visionLabel: petLabel(label),
                prompt: prompt
            )
        )
    }

    private func petState(_ state: DetectionState) -> SaboriState {
        switch state {
        case .normal: return .normal
        case .suspected: return .suspected
        case .confirmed: return .confirmed
        }
    }

    private func petStage(_ decision: DetectionDecision) -> Int {
        switch (decision.state, decision.evidence) {
        case (.suspected, _): return 1
        case (.confirmed, .none): return 2
        case (.confirmed, _): return 3
        default: return 0
        }
    }

    private func petLabel(_ label: SpeechRequest.VisionLabel) -> VisionLabel {
        switch label {
        case .sleeping: return .asleep
        case .lookingAway: return .lookingAway
        case .absent: return .absent
        case .unknown: return .none
        }
    }

    private func collectEvidence(_ kind: EvidenceKind) async -> Data? {
        switch kind {
        case .macCamera: return await actions.captureMacPhoto()
        case .iphoneScreenshot: return await actions.captureIPhoneScreenshot()
        case .none: return nil
        }
    }

    private func makeRequest(
        signals: DetectionSignals,
        decision: DetectionDecision,
        label: SpeechRequest.VisionLabel,
        screenshot: Data?
    ) -> SpeechRequest {
        SpeechRequest(
            idleSeconds: Int(signals.macIdleSeconds),
            escalation: escalation(for: decision),
            frontmostApp: signals.frontmostApp,
            iphone: signals.iphone,
            iphoneApp: signals.iphoneForegroundApp,
            vision: label,
            screenshotPNG: screenshot
        )
    }

    private func escalation(for decision: DetectionDecision) -> SpeechRequest.Escalation {
        switch (decision.state, decision.evidence) {
        case (.suspected, _): return .nudge
        case (.confirmed, .none): return .warn
        case (.confirmed, _): return .expose
        case (.normal, _): return .nudge
        }
    }

    private func filename(for kind: EvidenceKind) -> String {
        switch kind {
        case .macCamera: return "camera.png"
        case .iphoneScreenshot: return "iphone.png"
        case .none: return "evidence.png"
        }
    }

    private func record(_ decision: DetectionDecision, outcome: String, at now: Date) {
        Self.logger.info(
            "\(decision.state.rawValue, privacy: .public): \(decision.reason, privacy: .public) → \(outcome, privacy: .public)"
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
