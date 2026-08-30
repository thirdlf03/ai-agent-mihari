import AppKit

/// 在席スタンプのカットインを出す枠なしの浮遊パネル。
///
/// Touch ID のダイアログの手前に重なる位置に出るので、クリックは必ず下へ通す。
/// キーウィンドウにもならないので、指を置くまでの操作を一切邪魔しない。
final class AttendanceCutInWindow: NSPanel {

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
        // 認証ダイアログの操作を邪魔しないよう、クリックはすべて下へ通す。
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }
}
