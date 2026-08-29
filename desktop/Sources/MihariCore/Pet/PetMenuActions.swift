import Foundation

/// ペットのメニューから呼ぶアプリ全体の操作。
///
/// メニュー（`PetMenuContent`）はこの protocol と `PetController` だけを知っていればよく、
/// 監視・在席・休憩・設定画面の実体を知らなくてよい。アプリ側の取りまとめ役が適合する。
@MainActor
public protocol PetMenuActions: AnyObject, ObservableObject {
    /// 監視中か。メニューの表示を「監視を止める / 監視を再開する」で切り替えるのに使う。
    var isWatching: Bool { get }
    /// 休憩中か。メニューの表示を「休憩する / 休憩を終える」で切り替えるのに使う。
    var isOnBreak: Bool { get }

    /// 監視を始める。
    func startWatching()
    /// 監視を止める。
    func stopWatching()
    /// 在席スタンプ（Touch ID）を押す。
    func stampAttendance()
    /// 休憩を始める。
    func startBreak()
    /// 休憩を終える。
    func endBreak()
    /// Discord 設定の画面を開く。
    func openDiscordSettings()
    /// 権限の確認画面を開く。
    func openPermissions()
}
