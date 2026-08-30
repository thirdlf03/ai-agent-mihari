import Foundation
import Testing

@testable import MihariCore

@Suite("本体の生死を見る 1 回分の見回り")
struct AppWatchdogTests {

    private final class StubObserver: RunningApplicationObserving, @unchecked Sendable {
        var isRunningResult: Bool
        init(isRunningResult: Bool) { self.isRunningResult = isRunningResult }
        func isRunning(bundleIdentifier: String) -> Bool { isRunningResult }
    }

    private final class SpyLauncher: ApplicationLaunching, @unchecked Sendable {
        private(set) var launchedURLs: [URL] = []
        func launch(appURL: URL) { launchedURLs.append(appURL) }
    }

    @Test("本体が動いていれば何もしない")
    func doesNothingWhenRunning() {
        let observer = StubObserver(isRunningResult: true)
        let launcher = SpyLauncher()
        let watchdog = AppWatchdog(
            bundleIdentifier: "com.thirdlf03.mihari",
            appURL: URL(fileURLWithPath: "/Applications/Mihari.app"),
            observer: observer,
            launcher: launcher
        )

        watchdog.checkAndReviveIfNeeded()

        #expect(launcher.launchedURLs.isEmpty)
    }

    @Test("本体が消えていれば起こす")
    func revivesWhenNotRunning() {
        let observer = StubObserver(isRunningResult: false)
        let launcher = SpyLauncher()
        let appURL = URL(fileURLWithPath: "/Applications/Mihari.app")
        let watchdog = AppWatchdog(
            bundleIdentifier: "com.thirdlf03.mihari",
            appURL: appURL,
            observer: observer,
            launcher: launcher
        )

        watchdog.checkAndReviveIfNeeded()

        #expect(launcher.launchedURLs == [appURL])
    }
}
