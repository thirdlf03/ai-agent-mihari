import Foundation
import os

/// 監視プロセスの登録/解除の抽象。テストでは呼び出し回数だけを記録するスタブに差し替える。
public protocol WatchdogRegistering {
    /// まだ登録していなければ登録し、見張りを始めさせる。
    func ensureRegistered()
    /// 登録を解除する。ロックが解けた正規の終了のときだけ呼ぶ ―― 呼ばずに
    /// 本体だけを終了させると、監視プロセスが「消えた」と判断してまた起こしてしまう。
    func unregister()
    /// 登録が(`launchctl bootout` や plist 削除で)外から消されていたら、その場で
    /// 登録し直す。すでにあれば何もしない軽いチェックなので、本体が動いている間
    /// 繰り返し呼ぶ前提。これにより、ロック時間を経ない解除は長続きしない。
    func reassertIfMissing()
}

/// `~/Library/LaunchAgents/` に plist を書き、`launchctl` でユーザー権限の
/// LaunchAgent として登録する。root は不要。
public struct LaunchAgentWatchdogRegistrar: WatchdogRegistering {

    private static let logger = Logger(subsystem: WatchdogSetup.bundleIdentifier, category: "watchdog-registrar")

    private let homeDirectory: URL
    private let appBundlePath: String
    private let uid: uid_t

    /// - Parameters:
    ///   - appBundlePath: 見張られる側、つまり自分自身の `Mihari.app` のパス。
    public init(
        appBundlePath: String = Bundle.main.bundlePath,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        uid: uid_t = getuid()
    ) {
        self.appBundlePath = appBundlePath
        self.homeDirectory = homeDirectory
        self.uid = uid
    }

    public func ensureRegistered() {
        let plistURL = WatchdogSetup.plistURL(homeDirectory: homeDirectory)
        let contents = WatchdogSetup.plistContents(appBundlePath: appBundlePath)

        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            Self.logger.error("watchdog plist の書き込みに失敗: \(error.localizedDescription, privacy: .public)")
            return
        }

        // すでに古い内容(パスが変わった等)で読み込まれている可能性があるので、
        // 一度降ろしてから読み込み直す。降ろす対象が無くても bootout はエラーで
        // 終わるだけなので、ここでは結果を見ない。
        let domain = WatchdogSetup.guiDomainTarget(uid: uid)
        Self.run(["bootout", "\(domain)/\(WatchdogSetup.label)"])
        Self.run(["bootstrap", domain, plistURL.path])
    }

    public func unregister() {
        let domain = WatchdogSetup.guiDomainTarget(uid: uid)
        Self.run(["bootout", "\(domain)/\(WatchdogSetup.label)"])

        let plistURL = WatchdogSetup.plistURL(homeDirectory: homeDirectory)
        try? FileManager.default.removeItem(at: plistURL)
    }

    public func reassertIfMissing() {
        let domain = WatchdogSetup.guiDomainTarget(uid: uid)
        guard !Self.isLoaded(domain: domain) else { return }
        Self.logger.error("watchdog の登録が外から消されていた。登録し直す")
        ensureRegistered()
    }

    /// `launchctl print` の終了コードで、指定の label が読み込まれているかを見る。
    /// 見つかれば 0、見つからなければ非 0 を返す(標準的な launchctl の流儀)。
    private static func isLoaded(domain: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "\(domain)/\(WatchdogSetup.label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            logger.error("launchctl print の起動に失敗: \(error.localizedDescription, privacy: .public)")
            return true  // 確かめられないなら、余計な再登録の連打を避けて「ある」とみなす。
        }
    }

    private static func run(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("launchctl の起動に失敗: \(error.localizedDescription, privacy: .public)")
        }
    }
}
