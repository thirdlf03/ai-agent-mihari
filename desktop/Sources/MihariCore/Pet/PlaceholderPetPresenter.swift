import AppKit
import SwiftUI
import os

/// `PetPresenting` の暫定実装。画像1枚（またはプレースホルダの SF Symbol）を最前面ウィンドウに出し、
/// イベントのセリフを吹き出しで順番に流す。
///
/// 本実装が来たら、この型の代わりに `PetPresenting` に適合する新しい型を用意して差し替える。
/// ウィンドウの生成は `show()` が呼ばれるまで行わないため、テストからこの型を new しても
/// ウィンドウは出ない（`present` や `answerPrompt` だけを呼べば副作用なく検証できる）。
@MainActor
public final class PlaceholderPetPresenter: ObservableObject, PetPresenting {
    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "pet")

    /// 初期表示位置を決めるときの、画面端からの余白。
    static let screenMargin: CGFloat = 24

    @Published public private(set) var state: SaboriState = .normal
    @Published public private(set) var visionLabel: VisionLabel = .none
    @Published public private(set) var speechText: String?
    @Published public private(set) var pendingPrompt: PetYesNoPrompt?
    @Published public private(set) var imageSource: PetImageSource
    @Published public private(set) var isVisible = false

    /// 画像パスなどの設定。変更すると `imageSource` を再判定する。
    public var configuration: PetConfiguration {
        didSet { imageSource = PetImageResolver.resolve(configuration: configuration) }
    }

    /// セリフの待ち行列。`internal` にして、テストから `@testable import` 経由で中身を確認できるようにしている。
    var speechQueue = PetSpeechQueue()
    private var dismissTask: Task<Void, Never>?
    private var panel: NSPanel?

    public init(configuration: PetConfiguration = .default) {
        self.configuration = configuration
        self.imageSource = PetImageResolver.resolve(configuration: configuration)
    }

    // MARK: - PetPresenting

    public func present(_ event: PetEvent) {
        state = event.state
        visionLabel = event.visionLabel
        pendingPrompt = event.prompt
        Self.logger.debug(
            "pet event: state=\(event.state.rawValue, privacy: .public) stage=\(event.escalationStage, privacy: .public)"
        )

        guard !event.line.isEmpty else { return }
        speechQueue.enqueue(event.line)
        advanceSpeechQueueIfIdle()
    }

    public func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
        isVisible = true
    }

    public func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    /// 問いかけに回答する。吹き出しのボタンからも、AirPods の首振り判定（#18）からも
    /// これを呼べば同じように分岐できる。
    public func answerPrompt(_ answer: Bool) {
        let prompt = pendingPrompt
        pendingPrompt = nil
        prompt?.onAnswer(answer)
    }

    // MARK: - セリフのキュー

    private func advanceSpeechQueueIfIdle() {
        guard speechText == nil, let next = speechQueue.dequeue() else { return }
        speechText = next
        scheduleDismiss(for: next)
    }

    private func scheduleDismiss(for line: String) {
        dismissTask?.cancel()
        let duration = PetBubbleDurationPolicy.duration(for: line)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, !Task.isCancelled else { return }
            self.speechText = nil
            self.advanceSpeechQueueIfIdle()
        }
    }

    // MARK: - ウィンドウ

    private func makePanel() -> NSPanel {
        let size = configuration.windowSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // .floating: 通常のウィンドウよりは前に出るが、キーウィンドウにならない
        // (.nonactivatingPanel) ので、クリックやドラッグで他アプリからフォーカスを奪わない。
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        // 全画面アプリの Space までは追いかけない。既定の挙動（作られた Space にしか出ない）に
        // 任せることで、全画面アプリの上に出続けて鬱陶しくなることを避けている。
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.contentView = NSHostingView(rootView: PetSceneView(presenter: self))
        positionInitialFrame(of: panel, size: size)
        return panel
    }

    private func positionInitialFrame(of panel: NSPanel, size: CGSize) {
        guard let frame = NSScreen.main?.visibleFrame else { return }
        let origin = NSPoint(
            x: frame.maxX - size.width - Self.screenMargin,
            y: frame.minY + Self.screenMargin
        )
        panel.setFrameOrigin(origin)
    }
}
