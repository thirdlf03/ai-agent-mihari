import Foundation
import Testing

@testable import MihariCore

/// 仕事ごとのイベント・カーソルの保存。
@Suite("部屋のカーソルの保存")
@MainActor
struct RoomEventCursorStoreTests {

    /// 実行のたびに空の UserDefaults を使い、テスト同士で共有しないようにする。
    private func makeStore() -> UserDefaultsRoomJobCursorStore {
        let suiteName = "mihari.test.roomCursor.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return UserDefaultsRoomJobCursorStore(defaults: defaults)
    }

    @Test("仕事ごとにカーソルを保存して読み直せる")
    func storesPerJob() {
        let store = makeStore()
        #expect(store.cursor(for: "abc") == nil)

        store.setCursor("ev-5", for: "abc")
        store.setCursor("ev-2", for: "def")

        #expect(store.cursor(for: "abc") == "ev-5")
        #expect(store.cursor(for: "def") == "ev-2")
    }

    @Test("nil でカーソルを消せる")
    func clearsCursor() {
        let store = makeStore()
        store.setCursor("ev-5", for: "abc")
        store.setCursor(nil, for: "abc")
        #expect(store.cursor(for: "abc") == nil)
    }

    @Test("最後に追った仕事の ID を覚える")
    func remembersLastJob() {
        let store = makeStore()
        #expect(store.lastJobID == nil)

        store.lastJobID = "abc"
        #expect(store.lastJobID == "abc")

        store.lastJobID = nil
        #expect(store.lastJobID == nil)
    }

    @Test("別の仕事のカーソルは混ざらない")
    func keepsJobsSeparate() {
        let store = makeStore()
        store.setCursor("ev-9", for: "abc")
        store.setCursor("ev-1", for: "xyz")
        #expect(store.cursor(for: "abc") == "ev-9")
        #expect(store.cursor(for: "xyz") == "ev-1")
    }
}
