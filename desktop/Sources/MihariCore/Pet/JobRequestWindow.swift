import AppKit
import SwiftUI

/// 仕事の依頼窓。`AuxiliaryWindows` には足さず、ここで 1 枚だけ持ち回す。
///
/// ペットがキーウィンドウにならない関係で、開くときはアプリを前面に出す。
@MainActor
public final class JobRequestWindowController {

    /// アプリ全体で 1 つの依頼窓。閉じても捨てず、次は同じ窓を開き直す。
    public static let shared = JobRequestWindowController()

    private var window: NSWindow?

    public init() {}

    /// 依頼窓を出す。すでに出ていれば中身を差し替えて前面へ。
    public func show(client: JobRequestClient) {
        if let window {
            window.contentViewController = NSHostingController(rootView: JobRequestView(client: client))
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "仕事を頼む"
        // 閉じたあとも同じ窓を開き直すため、解放させない。
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: JobRequestView(client: client))
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// テストから窓の有無を見るための入り口。
    var isVisibleForTesting: Bool {
        window?.isVisible ?? false
    }
}
