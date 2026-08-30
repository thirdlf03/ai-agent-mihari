import Foundation
import Testing

@testable import MihariCore

@Suite("音声モードの決め方")
@MainActor
struct VoiceModeStoreTests {

    /// 実行のたびに空の UserDefaults を使い、テスト同士が設定を共有しないようにする。
    private func makeDefaults() -> UserDefaults {
        let suiteName = "mihari.test.voiceMode.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("何も無ければ同封音声")
    func defaultsToBundled() {
        #expect(VoiceModeStore.initialMode(defaults: makeDefaults(), environment: [:]) == .bundled)
    }

    @Test("保存してあればそれを使う")
    func storedValueWins() {
        let defaults = makeDefaults()
        defaults.set(VoiceMode.live.rawValue, forKey: VoiceModeStore.defaultsKey)

        #expect(VoiceModeStore.initialMode(defaults: defaults, environment: [:]) == .live)
    }

    @Test("環境変数は保存値より強い")
    func environmentBeatsStoredValue() {
        let defaults = makeDefaults()
        defaults.set(VoiceMode.bundled.rawValue, forKey: VoiceModeStore.defaultsKey)

        let mode = VoiceModeStore.initialMode(
            defaults: defaults,
            environment: [VoiceModeStore.environmentKey: "live"]
        )

        #expect(mode == .live)
    }

    @Test("知らない値は無視して次の候補に落ちる")
    func unknownValuesAreIgnored() {
        let defaults = makeDefaults()
        defaults.set("mumble", forKey: VoiceModeStore.defaultsKey)

        let fromDefaults = VoiceModeStore.initialMode(defaults: defaults, environment: [:])
        #expect(fromDefaults == .bundled)

        defaults.set(VoiceMode.live.rawValue, forKey: VoiceModeStore.defaultsKey)
        let fromEnvironment = VoiceModeStore.initialMode(
            defaults: defaults,
            environment: [VoiceModeStore.environmentKey: "mumble"]
        )
        #expect(fromEnvironment == .live)
    }

    @Test("切り替えると覚えておく")
    func switchingIsRemembered() {
        let defaults = makeDefaults()
        let store = VoiceModeStore(defaults: defaults, environment: [:])
        #expect(store.mode == .bundled)

        store.set(.live)

        #expect(store.mode == .live)
        #expect(VoiceModeStore(defaults: defaults, environment: [:]).mode == .live)
    }
}
