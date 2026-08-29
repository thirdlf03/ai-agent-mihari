import AppKit
import SwiftUI

/// ペットを表示する枠なしの浮遊パネル。他のアプリの上に出るが、キーウィンドウにはならない。
final class PetWindow: NSPanel {
    init(controller: PetController) {
        super.init(
            contentRect: CGRect(origin: .zero, size: PetSpriteGrid.cellSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        // ホバー時のツールチップを出すためにマウス移動イベントを受け取る。
        acceptsMouseMovedEvents = true

        let hostingView = NSHostingView(rootView: PetView().environment(controller))
        hostingView.frame = CGRect(origin: .zero, size: PetSpriteGrid.cellSize)
        contentView = hostingView
    }

    /// クリックは受け取るが、キーウィンドウにはならない。
    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }
}
