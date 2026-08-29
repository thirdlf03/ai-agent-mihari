import AppKit
import SwiftUI

/// 状態パネルを表示する枠なしの浮遊パネル。
///
/// ペットと同じ流儀で出すが、ペットのウィンドウとは独立して動かせる。
/// 置いた場所は覚えておく。デバッグのたびに毎回同じ隅へ戻されると邪魔になる。
final class StatusPanelWindow: NSPanel, NSWindowDelegate {

    /// 画面の端からあける余白(pt)。
    private static let margin: CGFloat = 16

    private enum DefaultsKey {
        static let originX = "statusPanel.originX"
        static let originY = "statusPanel.originY"
    }

    private let defaults: UserDefaults

    init<Content: View>(defaults: UserDefaults, content: Content) {
        self.defaults = defaults
        super.init(
            contentRect: CGRect(origin: .zero, size: CGSize(width: StatusPanelView.width, height: 1)),
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
        // ボタンを置いていないので、どこを掴んでも動かせる。
        isMovableByWindowBackground = true

        let hosting = NSHostingController(rootView: content)
        contentViewController = hosting
        hosting.view.layoutSubtreeIfNeeded()
        setContentSize(hosting.view.fittingSize)

        setFrameOrigin(restoredOrigin(size: frame.size))
        // 置き直しが終わってから見張り始める。初期配置を保存し直す必要はない。
        delegate = self
    }

    /// クリックは受け取るが、キーウィンドウにはならない。
    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }

    func windowDidMove(_ notification: Notification) {
        defaults.set(Double(frame.origin.x), forKey: DefaultsKey.originX)
        defaults.set(Double(frame.origin.y), forKey: DefaultsKey.originY)
    }

    /// 保存された位置を復元する。どの画面にも収まらなければメインスクリーンの右下に置く。
    private func restoredOrigin(size: CGSize) -> CGPoint {
        if let stored = storedOrigin(),
            let screen = NSScreen.screens.first(where: {
                $0.visibleFrame.intersects(CGRect(origin: stored, size: size))
            })
        {
            return Self.clamp(origin: stored, size: size, in: screen.visibleFrame)
        }

        let bounds = NSScreen.main?.visibleFrame ?? .zero
        return CGPoint(
            x: bounds.maxX - size.width - Self.margin,
            y: bounds.minY + Self.margin
        )
    }

    private func storedOrigin() -> CGPoint? {
        guard let x = defaults.object(forKey: DefaultsKey.originX) as? Double,
            let y = defaults.object(forKey: DefaultsKey.originY) as? Double
        else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    private static func clamp(origin: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, bounds.minX), max(bounds.maxX - size.width, bounds.minX)),
            y: min(max(origin.y, bounds.minY), max(bounds.maxY - size.height, bounds.minY))
        )
    }
}
