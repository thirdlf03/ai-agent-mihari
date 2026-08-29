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

    /// このエピソード（正常に戻るまで）で見たサボり確定の最大段階。段階が上がったときだけ跳ねる。
    private var maxConfirmedStage: Int?
    /// 問いかけを出しているあいだに届いたセリフ。問いかけが閉じてから出す。
    private var heldLine: String?

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
            maxConfirmedStage = nil
        case .suspected:
            directive.fixedAnimation = .waiting
        case .confirmed:
            directive.fixedAnimation = .failed
            // 段階が上がったときだけ跳ねる。3→2→3 の往復では跳ねない。
            if event.escalationStage > (maxConfirmedStage ?? Int.min) {
                maxConfirmedStage = event.escalationStage
                directive.playOnce = .jumping
            }
        }

        // 問いかけを出しているあいだは、答えを待つ姿のまま止める。
        if pendingPrompt != nil || event.prompt != nil {
            directive.fixedAnimation = .waiting
        }
        // 正常時は吹き出しを出さない。
        if event.state != .normal, !event.line.isEmpty {
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
            controller.showPrompt(question: prompt.question) { [weak self] answer in
                self?.answerPrompt(answer)
            }
        }
        if let line = directive.line {
            if pendingPrompt != nil {
                heldLine = line
            } else {
                // 音声は検知側が別経路で鳴らすので、ここでは吹き出しだけ出す。
                controller.say(line, voiced: false)
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
        guard let line = heldLine else { return }
        heldLine = nil
        controller.say(line, voiced: false)
    }
}
