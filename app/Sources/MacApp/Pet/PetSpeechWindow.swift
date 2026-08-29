import AppKit
import SwiftUI

/// ペットのセリフを出す枠なしの浮遊パネル。ペットウィンドウの子にして一緒に動かす。
final class PetSpeechWindow: NSPanel {
    /// 吹き出しの先端とペットウィンドウの端のあいだにあける隙間(pt)。ペットに被らないよう外側に離す。
    private static let gap: CGFloat = 6
    /// 表示・非表示のフェードにかける時間(秒)。
    private static let fadeDuration: TimeInterval = 0.15

    /// いま出しているセリフ。消しているあいだは nil。
    private var currentText: String?

    init() {
        super.init(
            contentRect: CGRect(origin: .zero, size: CGSize(width: 1, height: 1)),
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
        // クリックはペットや下のウィンドウへそのまま通す。
        ignoresMouseEvents = true
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }

    /// セリフを表示する。表示中なら中身と位置を差し替える。
    func show(text: String, above petWindow: NSWindow, animated: Bool) {
        layout(text: text, above: petWindow)
        if parent !== petWindow {
            parent?.removeChildWindow(self)
            petWindow.addChildWindow(self, ordered: .above)
        }
        fade(to: 1, animated: animated, then: nil)
    }

    /// 吹き出しを消す。フェードが終わってからウィンドウを片付ける。
    func hide(animated: Bool) {
        guard currentText != nil else { return }
        currentText = nil
        fade(to: 0, animated: animated) { [weak self] in
            // フェード中に次のセリフが来ていたら片付けない。
            guard let self, currentText == nil else { return }
            parent?.removeChildWindow(self)
            orderOut(nil)
        }
    }

    /// 表示中の吹き出しを、いまのペットウィンドウに合わせて置き直す。
    func reposition(above petWindow: NSWindow) {
        guard let currentText else { return }
        layout(text: currentText, above: petWindow)
    }

    /// 中身を作り直し、ペットウィンドウを基準に大きさと位置を決める。
    private func layout(text: String, above petWindow: NSWindow) {
        currentText = text

        // しっぽの向きで大きさは変わらないので、下向きで測ってから置き場所を決める。
        let hostingView = NSHostingView(rootView: PetSpeechBubbleView(text: text, tailAtBottom: true))
        // SwiftUI の理想サイズでウィンドウが勝手にリサイズされないようにする。大きさはこちらで決める。
        hostingView.sizingOptions = []
        let size = PetSpeechBubbleView.windowSize(for: text)
        let bounds = petWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let placement = Self.placement(petFrame: petWindow.frame, size: size, in: bounds)
        if !placement.tailAtBottom {
            hostingView.rootView = PetSpeechBubbleView(text: text, tailAtBottom: false)
        }
        hostingView.frame = CGRect(origin: .zero, size: size)
        contentView = hostingView
        setFrame(CGRect(origin: placement.origin, size: size), display: true)
    }

    /// 透明度を変える。`animated` が false なら即座に反映する。
    private func fade(to alpha: CGFloat, animated: Bool, then completion: (() -> Void)?) {
        guard animated else {
            alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated {
                completion?()
            }
        }
    }

    /// 吹き出しの置き場所。
    private struct Placement {
        /// ウィンドウの原点(スクリーン座標の左下)。
        let origin: CGPoint
        /// しっぽを下に出すか。
        let tailAtBottom: Bool
    }

    /// ペットの真上・水平中央に、ペットと被らないよう隙間をあけて置く。上に収まらなければ下へ出し、左右のはみ出しは画面内へ寄せる。
    private static func placement(petFrame: CGRect, size: CGSize, in bounds: CGRect?) -> Placement {
        var x = petFrame.midX - size.width / 2
        if let bounds {
            x = min(max(x, bounds.minX), max(bounds.maxX - size.width, bounds.minX))
        }

        // 板の縁はウィンドウの端から margin だけ内側にあるので、その分を差し引いて隙間をあける。
        let above = petFrame.maxY + Self.gap - PetSpeechBubbleView.margin
        if let bounds, above + size.height > bounds.maxY {
            let below = petFrame.minY - Self.gap + PetSpeechBubbleView.margin - size.height
            return Placement(origin: CGPoint(x: x, y: below), tailAtBottom: false)
        }
        return Placement(origin: CGPoint(x: x, y: above), tailAtBottom: true)
    }
}
