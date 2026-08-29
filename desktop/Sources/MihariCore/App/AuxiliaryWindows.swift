import AppKit
import SwiftUI

/// ふだんは出さない補助ウィンドウ(権限 / Discord 設定 / デバッグ UI)の置き場。
///
/// Mihari の本体はデスクトップのペットで、ウィンドウは必要になったときだけ出す。
/// そのため SwiftUI の `WindowGroup` は使わず、ここで `NSWindow` を直接組み立てて使い回す。
/// `isReleasedWhenClosed = false` にしてあるので、閉じても同じウィンドウを開き直せる。
@MainActor
final class AuxiliaryWindows {

    private var permissions: NSWindow?
    private var discord: NSWindow?
    private var debug: NSWindow?

    /// 権限の確認画面を出す(すでに出ていれば中身を差し替えて前面へ)。
    ///
    /// 「始める」と「閉じる」でボタンが変わるため、開くたびに中身を作り直す。
    func showPermissions<Content: View>(@ViewBuilder content: () -> Content) {
        permissions = present(
            permissions,
            title: "権限の確認",
            size: NSSize(width: 900, height: 640),
            content: content()
        )
    }

    /// 権限の確認画面を閉じる。出していなければ何もしない。
    func closePermissions() {
        permissions?.close()
    }

    /// Discord 設定の画面を出す。
    func showDiscord<Content: View>(@ViewBuilder content: () -> Content) {
        discord = present(
            discord,
            title: "Discord 設定",
            size: NSSize(width: 640, height: 720),
            content: content()
        )
    }

    /// 検証用の 10 タブ画面を出す。`MIHARI_DEBUG_UI=1` のときだけ使う。
    func showDebug<Content: View>(@ViewBuilder content: () -> Content) {
        debug = present(
            debug,
            title: "Mihari (検証用)",
            size: NSSize(width: 940, height: 720),
            content: content()
        )
    }

    /// 既にあるウィンドウなら中身を差し替えて前面に出し、無ければ作る。
    private func present<Content: View>(
        _ existing: NSWindow?,
        title: String,
        size: NSSize,
        content: Content
    ) -> NSWindow {
        let window = existing ?? makeWindow(title: title)
        window.contentViewController = NSHostingController(rootView: content)
        // 大きさと位置は最初に開いたときだけ決める。次からはユーザーが動かした場所を尊重する。
        if existing == nil {
            window.setContentSize(size)
            window.center()
        }
        // ペットはキーウィンドウにならないため、アプリ自体が前に出ていないことがある。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func makeWindow(title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        // 閉じたあとも同じウィンドウを開き直すため、解放させない。
        window.isReleasedWhenClosed = false
        return window
    }
}
