import AppKit

/// 本体アプリが動いているかを見る。テストでは記録だけするスタブに差し替える。
public protocol RunningApplicationObserving {
    func isRunning(bundleIdentifier: String) -> Bool
}

/// 本体アプリを起こす。テストでは記録だけするスタブに差し替える。
public protocol ApplicationLaunching {
    func launch(appURL: URL)
}

/// `NSRunningApplication` で実際に見る実装。
public struct NSWorkspaceApplicationObserver: RunningApplicationObserving {
    public init() {}

    public func isRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}

/// `NSWorkspace` で実際に起こす実装。
public struct NSWorkspaceApplicationLauncher: ApplicationLaunching {
    public init() {}

    public func launch(appURL: URL) {
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// 「本体が消えていたら起こす」の 1 回分の見回り。
///
/// `MihariWatchdog` 実行可能ターゲットの `main.swift` はこれをループで呼ぶだけの薄い皮に
/// してあり、判定・起動の実処理はここに閉じ込めて単体テストできるようにしている。
public struct AppWatchdog {
    private let bundleIdentifier: String
    private let appURL: URL
    private let observer: RunningApplicationObserving
    private let launcher: ApplicationLaunching

    public init(
        bundleIdentifier: String,
        appURL: URL,
        observer: RunningApplicationObserving = NSWorkspaceApplicationObserver(),
        launcher: ApplicationLaunching = NSWorkspaceApplicationLauncher()
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appURL = appURL
        self.observer = observer
        self.launcher = launcher
    }

    /// 動いていなければ起こす。動いていれば何もしない。
    public func checkAndReviveIfNeeded() {
        guard !observer.isRunning(bundleIdentifier: bundleIdentifier) else { return }
        launcher.launch(appURL: appURL)
    }
}
