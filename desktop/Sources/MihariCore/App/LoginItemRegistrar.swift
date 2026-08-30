import ServiceManagement
import os

/// ログイン項目への登録の抽象。テストでは呼び出し回数だけを記録するスタブに差し替える。
public protocol LoginItemRegistering {
    /// まだ有効でなければ登録する。すでに有効なら何もしない。
    func ensureRegistered()
    /// 登録を解除する。ロックが解けた正規の終了のときに呼ぶ。
    func unregister()
}

/// `SMAppService.mainApp` でログイン項目に登録する。
///
/// `kill` されて落ちても、次回ログイン(または今回のセッションへの復帰)で自動的に
/// 起動し直る ―― 「一度殺せば終わり」を防ぐのが目的。即座の再起動(ウォッチドッグ)
/// までは行わない。登録に失敗しても致命的には扱わず、ログに残すだけで続行する。
public struct SMAppServiceLoginItemRegistrar: LoginItemRegistering {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "login-item")

    public init() {}

    public func ensureRegistered() {
        let service = SMAppService.mainApp
        guard service.status != .enabled else { return }
        do {
            try service.register()
        } catch {
            Self.logger.error("ログイン項目への登録に失敗: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func unregister() {
        let service = SMAppService.mainApp
        guard service.status == .enabled else { return }
        do {
            try service.unregister()
        } catch {
            Self.logger.error("ログイン項目の解除に失敗: \(error.localizedDescription, privacy: .public)")
        }
    }
}
