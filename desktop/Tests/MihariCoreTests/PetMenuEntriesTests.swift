import Foundation
import Testing

@testable import MihariCore

/// ペットメニューの並びが、そのときの状態をチェックに映すかを検証する。
@Suite("ペットメニューの並び")
@MainActor
struct PetMenuEntriesTests {

    /// 実行のたびに空の UserDefaults を使い、テスト同士が表示設定を共有しないようにする。
    private func makePresenter() -> LivePetPresenter {
        let suiteName = "mihari.test.petMenu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return LivePetPresenter(controller: PetController(defaults: defaults))
    }

    /// タイトルの一致する項目を探す。
    private func findItem(
        _ title: String,
        in entries: [PetMenuEntry]
    ) -> (isChecked: Bool, action: @MainActor () -> Void)? {
        for entry in entries {
            if case .item(let itemTitle, let isChecked, let action) = entry, itemTitle == title {
                return (isChecked, action)
            }
        }
        return nil
    }

    @Test("「スクショに写り込む」のチェックは写り込みの入り / 切りを映し、押すと切り替わる")
    func photobombEntryReflectsAndTogglesTheSetting() throws {
        let presenter = makePresenter()
        let actions = StubPetMenuActions()

        let enabled = try #require(
            findItem("スクショに写り込む", in: PetMenuEntries.make(actions: actions, presenter: presenter))
        )
        #expect(enabled.isChecked)

        enabled.action()
        #expect(actions.isPhotobombEnabled == false)

        let disabled = try #require(
            findItem("スクショに写り込む", in: PetMenuEntries.make(actions: actions, presenter: presenter))
        )
        #expect(disabled.isChecked == false)
    }
}
