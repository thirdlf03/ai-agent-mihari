import AppKit
import SwiftUI

/// 仕事の依頼・追記窓。`AuxiliaryWindows` には足さず、ここで 1 枚だけ持ち回す。
///
/// ペットがキーウィンドウにならない関係で、開くときはアプリを前面に出す。
@MainActor
public final class JobRequestWindowController {

    /// アプリ全体で 1 つの依頼窓。閉じても捨てず、次は同じ窓を開き直す。
    public static let shared = JobRequestWindowController()

    private var window: NSWindow?

    public init() {}

    /// 新しく仕事を頼む窓を出す。
    ///
    /// `onSubmitted` は依頼が通ったあとに `(jobID, title)` で呼ばれる。アプリ側が
    /// その仕事の進捗を監視し始めるのに使う。
    public func show(
        client: JobRequestClient,
        onSubmitted: @escaping @MainActor (String, String) -> Void = { _, _ in }
    ) {
        show(
            JobRequestView(client: client, onSubmitted: onSubmitted),
            title: "仕事を頼む"
        )
    }

    /// 走っている仕事へ追記する窓を出す。
    public func showFollowup(client: RoomEventClient, jobID: String) {
        show(
            JobRequestView(followupClient: client, jobID: jobID),
            title: "追記する"
        )
    }

    /// 中身を差し替えて前面へ出す。すでに出ていれば同じ窓に載せ替える。
    private func show(_ content: some View, title: String) {
        if let window {
            window.contentViewController = NSHostingController(rootView: AnyView(content))
            window.title = title
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        // 閉じたあとも同じ窓を開き直すため、解放させない。
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: AnyView(content))
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
