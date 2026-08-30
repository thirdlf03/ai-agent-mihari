import Foundation
import Testing

@testable import MihariCore

@Suite("監視プロセスの LaunchAgent 登録内容")
struct WatchdogSetupTests {

    @Test("plist の設置先は ~/Library/LaunchAgents 配下")
    func plistURLIsUnderLaunchAgents() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let url = WatchdogSetup.plistURL(homeDirectory: home)

        #expect(url.path == "/Users/tester/Library/LaunchAgents/com.thirdlf03.mihari.watchdog.plist")
    }

    @Test("監視バイナリは Contents/MacOS に本体と並べて置かれている前提")
    func watchdogExecutablePathIsSiblingOfMainBinary() {
        let path = WatchdogSetup.watchdogExecutablePath(appBundlePath: "/Applications/Mihari.app")

        #expect(path == "/Applications/Mihari.app/Contents/MacOS/MihariWatchdog")
    }

    @Test("plist には KeepAlive と RunAtLoad が true で入っている")
    func plistContentsIncludeKeepAliveAndRunAtLoad() {
        let contents = WatchdogSetup.plistContents(appBundlePath: "/Applications/Mihari.app")

        #expect(contents.contains("<key>KeepAlive</key>"))
        #expect(contents.contains("<key>RunAtLoad</key>"))
        #expect(contents.contains("/Applications/Mihari.app/Contents/MacOS/MihariWatchdog"))
        #expect(contents.contains("/Applications/Mihari.app"))
        #expect(contents.contains(WatchdogSetup.label))
    }

    @Test("plist は妥当な XML として解釈できる")
    func plistContentsAreValidPropertyList() throws {
        let contents = WatchdogSetup.plistContents(appBundlePath: "/Applications/Mihari.app")
        let data = try #require(contents.data(using: .utf8))

        let plist =
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]

        #expect(plist?["Label"] as? String == WatchdogSetup.label)
        #expect(plist?["KeepAlive"] as? Bool == true)
        #expect(plist?["RunAtLoad"] as? Bool == true)
        #expect(
            plist?["ProgramArguments"] as? [String] == [
                "/Applications/Mihari.app/Contents/MacOS/MihariWatchdog",
                "/Applications/Mihari.app",
            ]
        )
    }

    @Test("GUI ドメインは gui/<uid> の形")
    func guiDomainTargetFormatsUID() {
        #expect(WatchdogSetup.guiDomainTarget(uid: 501) == "gui/501")
    }
}
