import IOKit.pwr_mgt
import os

/// スリープ防止の抽象。テストでは呼び出し回数だけを記録するスタブに差し替える。
public protocol SleepPreventing: AnyObject {
    /// スリープを防ぎ始める。すでに防いでいるなら何もしない。
    func start()
    /// スリープ防止をやめる。防いでいないなら何もしない。
    func stop()
}

/// `IOPMAssertionCreateWithName` でディスプレイスリープとアイドルスリープの両方を止める。
///
/// `caffeinate -d -i` と同じ効果を、子プロセスを増やさず本体プロセスの assertion だけで実現する。
/// 監視中に画面が暗転して撮影・検知が止まってしまう事態を防ぐのが目的。
public final class IOPMSleepPreventer: SleepPreventing {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "sleep-preventer")

    private let reason: String
    private var assertionIDs: [IOPMAssertionID] = []

    /// - Parameter reason: システム設定の「アクティビティ」に出る理由文言。
    public init(reason: String = "Mihari が監視中") {
        self.reason = reason
    }

    public func start() {
        guard assertionIDs.isEmpty else { return }

        let types: [String] = [
            kIOPMAssertionTypeNoDisplaySleep,
            kIOPMAssertionTypeNoIdleSleep,
        ]
        var acquired: [IOPMAssertionID] = []
        for type in types {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id
            )
            guard result == kIOReturnSuccess else {
                Self.logger.error("assertion 取得に失敗(type=\(type, privacy: .public), result=\(result))")
                continue
            }
            acquired.append(id)
        }
        assertionIDs = acquired
    }

    public func stop() {
        guard !assertionIDs.isEmpty else { return }
        for id in assertionIDs {
            IOPMAssertionRelease(id)
        }
        assertionIDs = []
    }

    deinit {
        for id in assertionIDs {
            IOPMAssertionRelease(id)
        }
    }
}
