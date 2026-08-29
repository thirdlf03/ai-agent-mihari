import Foundation
import Testing

@testable import MihariCore

@Suite("在席スタンプ履歴の永続化")
struct AttendanceStoreTests {

    /// 実行のたびに空の UserDefaults を使い、テスト同士が履歴を共有しないようにする。
    private func makeDefaults() -> UserDefaults {
        let suiteName = "mihari.test.attendance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("保存前は履歴が空")
    func startsEmpty() {
        let store = AttendanceStore(defaults: makeDefaults())
        #expect(store.load().isEmpty)
    }

    @Test("追加したスタンプが読み直せる")
    func appendPersists() {
        let defaults = makeDefaults()
        let store = AttendanceStore(defaults: defaults)
        let stamp = AttendanceStamp(stampedAt: Date(), biometryTypeText: "Touch ID")

        let result = store.append(stamp, to: store.load())
        #expect(result == [stamp])

        let reloaded = AttendanceStore(defaults: defaults).load()
        #expect(reloaded == [stamp])
    }

    @Test("履歴は新しい順に並ぶ")
    func sortsNewestFirst() {
        let store = AttendanceStore(defaults: makeDefaults())
        let now = Date()
        let older = AttendanceStamp(stampedAt: now.addingTimeInterval(-100), biometryTypeText: "Touch ID")
        let newer = AttendanceStamp(stampedAt: now, biometryTypeText: "Touch ID")

        // わざと古いものを後から足しても、並び順は時刻基準になる。
        var stamps = store.append(older, to: [])
        stamps = store.append(newer, to: stamps)

        #expect(stamps == [newer, older])
        #expect(store.load() == [newer, older])
    }

    @Test("上限を超えた分は古いものから捨てられる")
    func trimsBeyondHistoryLimit() {
        let store = AttendanceStore(defaults: makeDefaults())
        let now = Date()
        let overflow = AttendanceStore.historyLimit + 5

        var stamps: [AttendanceStamp] = []
        for offset in 0..<overflow {
            let stamp = AttendanceStamp(
                stampedAt: now.addingTimeInterval(TimeInterval(offset)),
                biometryTypeText: "Touch ID"
            )
            stamps = store.append(stamp, to: stamps)
        }

        #expect(stamps.count == AttendanceStore.historyLimit)
        // 最後に追加した(=最も新しい)ものが先頭に残っている。
        #expect(stamps.first?.stampedAt == now.addingTimeInterval(TimeInterval(overflow - 1)))
        // 最初のほうに追加した古いものは捨てられている。
        #expect(!stamps.contains { $0.stampedAt == now })
    }
}
