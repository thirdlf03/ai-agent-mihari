import Foundation
import os

/// 1 件のイベントを受けてペットに与える指示。
///
/// `LivePetPresenter` が `PetEvent` を解釈した結果そのもので、テストからの観測点にもなる。
public struct PetDirective: Equatable, Sendable {
    /// 固定するアニメーション。nil なら自律行動に戻す。
    public var fixedAnimation: PetAnimation?
    /// 1 回だけ挟むアニメーション。
    public var playOnce: PetAnimation?
    /// 吹き出しに出すセリフ。nil なら出さない。
    public var line: String?

    public init(fixedAnimation: PetAnimation? = nil, playOnce: PetAnimation? = nil, line: String? = nil) {
        self.fixedAnimation = fixedAnimation
        self.playOnce = playOnce
        self.line = line
    }
}

/// `PetPresenting` の本実装。検知エンジンのイベントを、スプライトのペットの動き・吹き出し・
/// 問いかけに落とす。
///
/// ウィンドウを作るのは `show()` が呼ばれてからなので、テストからは `present` や `answerPrompt`
/// だけを呼べば副作用なく検証できる（結果は `lastDirective` に出る）。
@MainActor
public final class LivePetPresenter: ObservableObject, PetPresenting {
    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "pet")

    /// ペットの見た目そのものを持つ本体。メニューの組み立てにも使う。
    public let controller: PetController

    /// 直近のイベントのサボり状態。
    @Published public private(set) var state: SaboriState = .normal
    /// いまの監視状態。
    @Published public private(set) var monitoringMode: PetMonitoringMode = .watching
    /// 答えを待っている問いかけ。
    @Published public private(set) var pendingPrompt: PetYesNoPrompt?
    /// 直近の `present(_:)` でペットに与えた指示。
    @Published public private(set) var lastDirective = PetDirective()

    /// このエピソード（正常に戻るまで）で見たエスカレーション段階の最大値。段階が上がったときだけ跳ねる。
    private var maxEscalationStage: Int?
    /// 問いかけを出しているあいだに届いたセリフと、その読み上げ用の音声。問いかけが閉じてから出す。
    private var heldLine: (text: String, audio: Data?)?

    public init(controller: PetController = PetController()) {
        self.controller = controller
    }

    // MARK: - PetPresenting

    public func present(_ event: PetEvent) {
        Self.logger.debug(
            "pet event: state=\(event.state.rawValue, privacy: .public) stage=\(event.escalationStage, privacy: .public)"
        )

        var directive = PetDirective()
        switch event.state {
        case .normal:
            // 非 normal から戻ってきたときだけ手を振る。エピソードの段階もここで忘れる。
            if state != .normal { directive.playOnce = .waving }
            maxEscalationStage = nil
        case .suspected, .confirmed:
            // 疑いは待つ姿、晒し以降は落ち込んだ姿で固定する。
            directive.fixedAnimation = event.state == .suspected ? .waiting : .failed
            // 段階が上がったときだけ跳ねる。3→2→3 の往復では跳ねない。
            if event.escalationStage > (maxEscalationStage ?? Int.min) {
                maxEscalationStage = event.escalationStage
                // メンヘラモードは晒しの続きなので、跳ね直さない。
                if event.escalationStage != PetEvent.clingyStage { directive.playOnce = .jumping }
            }
        }

        // 問いかけを出しているあいだは、答えを待つ姿のまま止める。
        if pendingPrompt != nil || event.prompt != nil {
            directive.fixedAnimation = .waiting
        }
        // 正常に戻るときも、メンヘラモードから戻った一言などは吹き出しに出す。
        if !event.line.isEmpty {
            directive.line = event.line
        }

        state = event.state
        lastDirective = directive

        controller.setFixedAnimation(directive.fixedAnimation)
        if let once = directive.playOnce {
            controller.playOnce(once)
        }
        // 出している問いかけがあるあいだは、新しい問いかけを捨てて古い方の回答経路を生かす。
        if let prompt = event.prompt, pendingPrompt == nil {
            pendingPrompt = prompt
            controller.showPrompt(
                question: prompt.question,
                voice: Self.speechVoice(for: prompt.audio)
            ) { [weak self] answer in
                self?.answerPrompt(answer)
            }
        }
        if let line = directive.line {
            if pendingPrompt != nil {
                heldLine = (line, event.audio)
            } else {
                controller.say(line, voice: Self.speechVoice(for: event.audio))
            }
        }
    }

    public func show() {
        controller.reveal()
    }

    public func hide() {
        controller.conceal()
    }

    public func dismissPrompt() {
        guard pendingPrompt != nil else { return }
        pendingPrompt = nil
        controller.dismissPrompt()
        speakHeldLine()
    }

    public func setMonitoring(_ mode: PetMonitoringMode) {
        let previous = monitoringMode
        monitoringMode = mode
        controller.setFrozen(mode != .watching)

        // 監視が始まった瞬間だけ一言そえる。同じ状態を入れ直したときは喋らない。
        guard mode == .watching, previous != .watching else { return }
        controller.say(previous == .onBreak ? .breakEnd : .watchStart)
    }

    /// 集中が続いていることを褒める。
    ///
    /// 検知の状態は正常のままなので `present(_:)` に流すと吹き出しが捨てられる。
    /// 監視開始・休憩明けの一言と同じく、ペットに直接言わせる。
    public func sayFocusStreak() {
        controller.say(.focusStreak)
    }

    // MARK: - 問いかけ

    /// 問いかけに答える。吹き出しのボタンからも、AirPods の首振り判定（#18）からもここを通る。
    /// `onAnswer` は一度だけ呼ぶ。
    public func answerPrompt(_ answer: Bool) {
        guard let prompt = pendingPrompt else { return }
        pendingPrompt = nil
        controller.dismissPrompt()
        prompt.onAnswer(answer)
        speakHeldLine()
    }

    /// 問いかけのあいだ待たせていたセリフを出す。
    private func speakHeldLine() {
        guard let held = heldLine else { return }
        heldLine = nil
        controller.say(held.text, voice: Self.speechVoice(for: held.audio))
    }

    /// 検知側から届いた音声を、ペットの読み上げ方に写す。
    ///
    /// 音声が付いていれば吹き出しと同時に鳴らしてもらう。付いていなければ吹き出しだけ出す
    /// (ここで合成させると、検知のセリフが二重に鳴る)。
    private static func speechVoice(for audio: Data?) -> SpeechVoice {
        guard let audio else { return .none }
        return .prepared(audio, priority: .detection)
    }
}
