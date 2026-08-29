import AppKit

/// アプリのライフサイクルを受け取る窓口。
///
/// Mihari の本体はデスクトップのペットで、起動しても普通はウィンドウを出さない。
/// SwiftUI の `WindowGroup` は宣言しただけで起動時にウィンドウが開いてしまい、
/// それを抑える `Scene.defaultLaunchBehavior(.suppressed)` は macOS 15 以降にしかない。
/// そのため `Settings` シーンだけを宣言し、実ウィンドウの生成はここから行う。
@MainActor
public final class MihariAppDelegate: NSObject, NSApplicationDelegate {

    /// 全機能の取りまとめ役。メニューからも `delegate.coordinator` として使う。
    public let coordinator = AppCoordinator()

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.launch()
    }

    /// Dock のアイコンがクリックされた。しまわれているペットを出すだけで、ウィンドウは開かない。
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator.handleReopen()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
    }
}
