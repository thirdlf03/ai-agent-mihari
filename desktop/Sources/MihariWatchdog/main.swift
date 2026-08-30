import Foundation
import MihariCore

/// `launchctl` の LaunchAgent(KeepAlive)から起動される、Mihari 本体を見張るだけの薄いループ。
///
/// このプロセス自体が kill されても、`KeepAlive` によって launchd がすぐに立て直す。
/// 立て直されたこのプロセスが「本体が消えている」ことに気づいて起こす ―― という分業により、
/// 本体を殺すだけでは(このプロセスも一緒に殺さない限り)監視を止められない。
///
/// 起動引数は 1 つだけ: 監視対象の `Mihari.app` へのパス。

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: MihariWatchdog <path-to-Mihari.app>\n".utf8))
    exit(64)
}

let appURL = URL(fileURLWithPath: arguments[1])
let watchdog = AppWatchdog(bundleIdentifier: WatchdogSetup.bundleIdentifier, appURL: appURL)

/// 見回りの間隔。短すぎると無駄に CPU を使い、長すぎると「殺してから戻るまで」の
/// すきま時間が意味を持ち始める。2 秒は caffeinate 的な常駐監視として妥当な線。
let pollInterval: TimeInterval = 2

while true {
    watchdog.checkAndReviveIfNeeded()
    Thread.sleep(forTimeInterval: pollInterval)
}
