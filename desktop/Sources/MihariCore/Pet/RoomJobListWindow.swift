import AppKit
import SwiftUI

/// 仕事一覧の窓。待機・実行中・完了・失敗・中断を検索し、選んだ仕事の詳細を固定して開く。
///
/// 選択は固定されるので、別ジョブの進捗で操作対象（詳細・追記・中断）が変わらない。
/// `RoomJobDetailWindowController` と同じく、アプリ全体で 1 枚を持ち回す。
@MainActor
public final class RoomJobListWindowController {

    /// アプリ全体で 1 つの一覧窓。閉じても捨てず、次は同じ窓を開き直す。
    public static let shared = RoomJobListWindowController()

    private var window: NSWindow?
    private let readStore = UserDefaultsRoomJobReadStore(defaults: .standard)

    public init() {}

    /// 仕事一覧の窓を出す。`onOpenJob` は選択した仕事の詳細を開くために呼ばれる。
    public func show(
        access: any RoomAccess,
        monitor: RoomJobMonitor,
        onOpenJob: @escaping @MainActor (String) -> Void = { _ in },
        onOpenRequest: @escaping @MainActor () -> Void = {}
    ) {
        let content = RoomJobListView(
            access: access,
            monitor: monitor,
            readStore: readStore,
            onOpenJob: { jobID in
                Task { @MainActor in onOpenJob(jobID) }
            },
            onOpenRequest: {
                Task { @MainActor in onOpenRequest() }
            }
        )
        if let window {
            window.contentViewController = NSHostingController(rootView: AnyView(content))
            window.title = "仕事一覧"
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "仕事一覧"
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
