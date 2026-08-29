import Foundation
import notify

/// アプリの外から届く合図(Darwin 通知)を購読する。
///
/// 外部プロセスは `notifyutil -p <通知名>` を叩くだけで合図を送れる(macOS 標準、依存ゼロ)。
/// Darwin 通知はペイロードを運べないので、意味は通知名だけで表す。
/// アプリが起動していなければ通知は誰にも届かず消えるだけで、送る側は何も気にしなくてよい。
public final class ExternalTriggerListener {

    /// Claude Code の Stop フックが「応答を終えた」合図として投げる通知名。
    public static let claudeDoneName = "com.thirdlf03.mihari.claude.done"

    private var token: Int32 = 0
    private var registered = false

    public init() {}

    /// 購読を始める。すでに購読中なら何もしない。
    ///
    /// - Parameters:
    ///   - name: Darwin 通知名。
    ///   - queue: ハンドラを呼ぶキュー。
    ///   - handler: 通知が届くたびに呼ばれる。
    public func listen(name: String, queue: DispatchQueue = .main, handler: @escaping () -> Void) {
        guard !registered else { return }
        let status = notify_register_dispatch(name, &token, queue) { _ in handler() }
        registered = status == NOTIFY_STATUS_OK
    }

    /// 購読をやめる。
    public func stop() {
        guard registered else { return }
        notify_cancel(token)
        registered = false
    }

    deinit { stop() }
}
