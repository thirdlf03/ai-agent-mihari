import Foundation

/// 監視プロセス(`MihariWatchdog`)をユーザー権限の LaunchAgent として登録するための
/// 純粋なロジック(パスと plist の組み立てだけ)。
///
/// ファイルの書き込みや `launchctl` の実行そのものは `LaunchAgentWatchdogRegistrar` が行う。
/// ここを分離してあるのは、`TunneldSetup` と同じ理由 ―― 実際に launchd を叩かずに
/// 「何を書くか」だけを単体テストできるようにするため。
///
/// `~/Library/LaunchAgents/` はユーザー自身が書き込めるディレクトリなので、
/// (root が要る `tunneld` の LaunchDaemon とは違って)管理者パスワードは不要。
public enum WatchdogSetup {

    /// 本体アプリのバンドル ID。`Resources/Info.plist` の `CFBundleIdentifier` と一致させる。
    public static let bundleIdentifier = "com.thirdlf03.mihari"

    /// LaunchAgent の label。plist のファイル名にもそのまま使う。
    public static let label = "\(bundleIdentifier).watchdog"

    /// plist の設置先。
    public static func plistURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    /// `Mihari.app` のバンドルパスから、同梱された監視バイナリのパスを組み立てる。
    /// `build.sh` が `Contents/MacOS/Mihari` の隣に `Contents/MacOS/MihariWatchdog` を置く前提。
    public static func watchdogExecutablePath(appBundlePath: String) -> String {
        "\(appBundlePath)/Contents/MacOS/MihariWatchdog"
    }

    /// 登録する launchd plist の中身。
    ///
    /// - `KeepAlive`: この監視プロセス自身が kill されても launchd がすぐに立て直す。
    /// - `RunAtLoad`: 登録した直後から見張り始める。
    /// - `ProcessType`: Background にして App Nap などの対象から外す。
    public static func plistContents(appBundlePath: String) -> String {
        let watchdogPath = watchdogExecutablePath(appBundlePath: appBundlePath)
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \t<key>Label</key>
            \t<string>\(label)</string>
            \t<key>ProgramArguments</key>
            \t<array>
            \t\t<string>\(watchdogPath)</string>
            \t\t<string>\(appBundlePath)</string>
            \t</array>
            \t<key>KeepAlive</key>
            \t<true/>
            \t<key>RunAtLoad</key>
            \t<true/>
            \t<key>ProcessType</key>
            \t<string>Background</string>
            </dict>
            </plist>
            """
    }

    /// `launchctl` に渡す、現在ユーザーの GUI ドメイン(`gui/<uid>`)。
    public static func guiDomainTarget(uid: uid_t) -> String {
        "gui/\(uid)"
    }
}
