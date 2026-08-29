import AppKit

/// 説教オーバーレイ専用の全画面ウィンドウ。
///
/// borderless ウィンドウは既定で key(キー入力を受け取れる)になれないため `canBecomeKey` を
/// 上書きする。これをしないと Esc キーが `keyDown` まで届かず、緊急解除が効かない。
final class OverlayWindow: NSWindow {

    /// Esc キー(kVK_Escape)。
    static let escapeKeyCode: UInt16 = 53

    /// Esc キーが押されたときに呼ぶ。緊急解除に使う。
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == Self.escapeKeyCode {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}
