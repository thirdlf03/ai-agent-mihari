import Foundation
import Testing

@testable import MihariCore

@Suite("正常終了できたかの記録")
struct AppLifecycleMarkerTests {

    private func makeDefaults() -> UserDefaults {
        let suiteName = "mihari.test.lifecycle-marker.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("初回起動(記録が無い)なら正常終了扱い")
    func firstLaunchIsTreatedAsGraceful() {
        let marker = UserDefaultsLifecycleMarker(defaults: makeDefaults())

        #expect(marker.wasPreviousSessionGraceful())
    }

    @Test("セッション開始を記録した直後は正常終了していない扱い")
    func sessionStartedIsNotGraceful() {
        let marker = UserDefaultsLifecycleMarker(defaults: makeDefaults())

        marker.markSessionStarted()

        #expect(!marker.wasPreviousSessionGraceful())
    }

    @Test("正常終了を記録すれば、次は正常終了していた扱いに戻る")
    func gracefulShutdownIsRemembered() {
        let marker = UserDefaultsLifecycleMarker(defaults: makeDefaults())

        marker.markSessionStarted()
        marker.markGracefulShutdown()

        #expect(marker.wasPreviousSessionGraceful())
    }

    @Test("kill されたことを模した状態(開始したまま)は、正常終了ではない")
    func killedSessionStaysUngraceful() {
        let defaults = makeDefaults()
        let marker = UserDefaultsLifecycleMarker(defaults: defaults)
        marker.markSessionStarted()

        // プロセスを跨いでも同じ UserDefaults を見れば同じ結果になることを、
        // 別インスタンスから確かめる。
        let markerAfterRestart = UserDefaultsLifecycleMarker(defaults: defaults)

        #expect(!markerAfterRestart.wasPreviousSessionGraceful())
    }
}
