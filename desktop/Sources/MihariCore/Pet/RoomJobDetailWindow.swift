import AppKit
import SwiftUI

/// 仕事の詳細パネル(進捗・記憶の候補・成果物)。`JobRequestWindowController` と同じく使い回す。
///
/// 開くときはアプリを前面に出す。仕事が切り替わったら中身を載せ替える。
@MainActor
public final class RoomJobDetailWindowController {
    /// アプリ全体で 1 つの詳細パネル。閉じても捨てず、次は同じ窓を開き直す。
    public static let shared = RoomJobDetailWindowController()

    private var window: NSWindow?

    public init() {}

    /// 詳細パネルを出す。古い仕事の監視は `RoomJobMonitor.focus` 側で止める。
    /// `onPreviewAuthenticated` は非公開版のアプリ内プレビュー（認証ヘッダ付き）を開く口。
    public func show(
        monitor: RoomJobMonitor,
        jobID: String,
        onOpenArtifact: @escaping (URL) -> Void,
        onPreviewAuthenticated: @escaping (String, String) -> Void = { _, _ in }
    ) {
        let content = RoomJobDetailView(
            monitor: monitor,
            jobID: jobID,
            onOpenArtifact: onOpenArtifact,
            onPreviewAuthenticated: onPreviewAuthenticated
        )
        if let window {
            window.contentViewController = NSHostingController(rootView: AnyView(content))
            window.title = "仕事の詳細"
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "仕事の詳細"
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
