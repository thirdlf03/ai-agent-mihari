import AppKit
import SwiftUI

/// ペットを表示する枠なしの浮遊パネル。他のアプリの上に出るが、キーウィンドウにはならない。
final class PetWindow: NSPanel {
    private unowned let controller: PetController

    init(controller: PetController) {
        self.controller = controller
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

        let hostingView = NSHostingView(rootView: PetSpriteView().environment(controller))
        hostingView.frame = CGRect(origin: .zero, size: PetSpriteGrid.cellSize)
        contentView = hostingView
    }

    /// クリックは受け取るが、キーウィンドウにはならない。
    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }

    /// 右クリックと Ctrl+クリックでメニューを出す。
    ///
    /// SwiftUI 側はドラッグとクリックだけを見ており、Ctrl+クリックは左クリックとして
    /// ドラッグ操作に吸われてしまう。中身のビューへ渡す前にここで横取りする。
    override func sendEvent(_ event: NSEvent) {
        let isContextClick =
            event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard isContextClick else {
            super.sendEvent(event)
            return
        }
        showContextMenu(for: event)
    }

    /// クリックした位置にメニューを出す。中身がまだ差し込まれていなければ何もしない。
    private func showContextMenu(for event: NSEvent) {
        guard let menu = controller.contextMenuBuilder?(), let contentView else { return }
        menu.popUp(
            positioning: nil,
            at: contentView.convert(event.locationInWindow, from: nil),
            in: contentView
        )
    }
}
