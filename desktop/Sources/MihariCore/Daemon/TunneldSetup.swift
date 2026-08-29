import Foundation

/// tunneld(iOS 17+ の iPhone スクショに必要な RemoteXPC トンネルの常駐)の
/// 登録スクリプトを組み立てる純粋なロジック。
///
/// tunneld は root でしか動かせないため、アプリからは直接起動できない。
/// 代わりに `bridge/scripts/install_tunneld_daemon.sh` を macOS の
/// 管理者パスワードダイアログ(`do shell script … with administrator privileges`)
/// 経由で 1 回実行し、launchd(LaunchDaemon)に常駐を任せる。
public enum TunneldSetup {

    /// tunneld の HTTP API。ここが応答すれば常駐している。
    public static let apiURL = URL(string: "http://127.0.0.1:49151/")!

    /// 登録スクリプトを管理者権限で実行する AppleScript を組み立てる。
    public static func installScript(bridgeDirectory: String) -> String {
        let path = bridgeDirectory + "/scripts/install_tunneld_daemon.sh"
        return "do shell script \(appleScriptLiteral(path)) with administrator privileges"
    }

    /// AppleScript の文字列リテラルにする。引用符とバックスラッシュだけ気をつければよい。
    static func appleScriptLiteral(_ value: String) -> String {
        let escaped =
            value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// tunneld の API に到達できるか。起動直後は数秒かかるので短いタイムアウトで見る。
    public static func isReachable() async -> Bool {
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

/// オンボーディング画面に出す tunneld の状態と、アプリからの登録操作。
@MainActor
public final class TunneldModel: ObservableObject {

    public enum Status: Equatable {
        /// まだ確かめていない。
        case unknown
        /// 確認中。
        case checking
        /// 常駐していて API が応答する。
        case running
        /// 応答がない(未登録か、起動直後)。
        case notRunning
        /// 管理者パスワードダイアログを出して登録している最中。
        case installing
    }

    @Published public private(set) var status: Status = .unknown
    @Published public private(set) var message: String?

    private let probe: @Sendable () async -> Bool
    private let runner: AppleScriptRunning
    private let locator: DaemonLocator
    /// 登録直後、tunneld が API を開くまでの待ち。テストでは 0 にする。
    private let settleDelay: Duration

    public init(
        probe: @escaping @Sendable () async -> Bool = { await TunneldSetup.isReachable() },
        runner: AppleScriptRunning = SystemAppleScriptRunner(),
        locator: DaemonLocator = DaemonLocator(),
        settleDelay: Duration = .seconds(3)
    ) {
        self.probe = probe
        self.runner = runner
        self.locator = locator
        self.settleDelay = settleDelay
    }

    /// いまの状態を確かめる。
    public func refresh() async {
        guard status != .installing else { return }
        status = .checking
        status = await probe() ? .running : .notRunning
    }

    /// 管理者パスワードダイアログを出して LaunchDaemon を登録する。
    public func install() async {
        guard status != .installing else { return }
        status = .installing
        message = nil

        let bridge: String
        do {
            bridge = try locator.bridgeDirectory()
        } catch {
            status = .notRunning
            message = "bridge/ が見つからない。DEVICE_BRIDGE_DIR を設定する"
            return
        }

        let source = TunneldSetup.installScript(bridgeDirectory: bridge)
        let runner = self.runner
        // パスワードダイアログが閉じるまで返ってこない同期呼び出しなので、メインを塞がない。
        let outcome = await Task.detached { runner.run(source) }.value

        if outcome.succeeded {
            // 登録直後は tunneld の起動に数秒かかる。
            try? await Task.sleep(for: settleDelay)
            status = .unknown
            await refresh()
            message = status == .running ? "登録した。以後は再起動しても自動で立ち上がる" : "登録は完了したが、まだ応答がない。数秒待って再確認する"
        } else if outcome.errorNumber == -128 {
            status = .notRunning
            message = "キャンセルされた"
        } else {
            status = .notRunning
            message = "登録に失敗した(エラー \(outcome.errorNumber.map(String.init) ?? "不明"))"
        }
    }
}
