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

    /// `kill <pid>` / Ctrl+C(SIGTERM・SIGINT)の既定の即死を止め、確認フローに合流させる。
    private var terminationSignalGuard: TerminationSignalGuard?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.launch()
        installTerminationSignalGuard()
    }

    /// Dock のアイコンがクリックされた。しまわれているペットを出すだけで、ウィンドウは開かない。
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator.handleReopen()
    }

    /// Cmd+Q・Dock 右クリックの「終了」・アプリメニューの「終了」、すべてここを通る。
    ///
    /// Touch ID 確認は非同期なので `.terminateLater` を返し、確認が済んでから
    /// `NSApp.reply(toApplicationShouldTerminate:)` で結果を返す。
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor [coordinator] in
            let allowed = await coordinator.confirmQuit()
            NSApp.reply(toApplicationShouldTerminate: allowed)
        }
        return .terminateLater
    }

    public func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
    }

    /// `kill`/Ctrl+C は `applicationShouldTerminate` を経由しないため、別経路で確認を挟む。
    /// 確認が通ったら Cocoa のライフサイクルを介さず直接後片付けして終了する
    /// (`NSApp.terminate` に投げ直すと確認が二重にかかってしまうため)。
    private func installTerminationSignalGuard() {
        let guardian = TerminationSignalGuard { [coordinator] in
            Task { @MainActor in
                guard await coordinator.confirmQuit() else { return }
                coordinator.shutdown()
                exit(0)
            }
        }
        guardian.install()
        terminationSignalGuard = guardian
    }
}
