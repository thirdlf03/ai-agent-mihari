import AppKit
import Testing

@testable import MihariCore

@Suite("ペットの右クリックメニュー")
@MainActor
struct PetContextMenuTests {

    /// 項目が押された回数を覚えておく箱。
    private final class ActionCounter {
        private(set) var count = 0
        func record() { count += 1 }
    }

    @Test("項目を押すとクロージャが呼ばれる")
    func itemRunsItsAction() {
        // performActionForItem は NSApp 経由で action を送るので、先にアプリを作っておく。
        _ = NSApplication.shared
        let counter = ActionCounter()
        let menu = PetContextMenu.makeMenu([
            .item(title: "しゃべる", action: { counter.record() })
        ])

        menu.performActionForItem(at: 0)

        #expect(counter.count == 1)
    }

    @Test("サブメニューの項目を押してもクロージャが呼ばれる")
    func submenuItemRunsItsAction() {
        _ = NSApplication.shared
        let counter = ActionCounter()
        let menu = PetContextMenu.makeMenu([
            .submenu(title: "サイズ", entries: [.item(title: "大", action: { counter.record() })])
        ])

        let submenu = menu.items[0].submenu
        submenu?.performActionForItem(at: 0)

        #expect(counter.count == 1)
    }

    @Test("チェックの有無がそのまま項目の状態になる")
    func checkedStateFollowsEntry() {
        let menu = PetContextMenu.makeMenu([
            .item(title: "声を出す", isChecked: true, action: {}),
            .item(title: "状態パネルを表示", isChecked: false, action: {}),
        ])

        #expect(menu.items[0].state == .on)
        #expect(menu.items[1].state == .off)
    }

    @Test("サブメニューは入れ子になり、区切りは区切り線になる")
    func submenuAndSeparatorAreBuilt() {
        let menu = PetContextMenu.makeMenu([
            .submenu(title: "サイズ", entries: [.item(title: "小", action: {}), .item(title: "大", action: {})]),
            .separator,
        ])

        #expect(menu.items[0].title == "サイズ")
        #expect(menu.items[0].submenu?.items.count == 2)
        #expect(menu.items[0].submenu?.items.map { $0.title } == ["小", "大"])
        #expect(menu.items[1].isSeparatorItem)
    }

    @Test("自動での有効・無効判定に任せず、項目は押せるままにする")
    func itemsStayEnabled() {
        // キーウィンドウにならないパネルから出すので、AppKit に任せると項目が灰色になる。
        let menu = PetContextMenu.makeMenu([
            .item(title: "しゃべる", action: {}),
            .submenu(title: "サイズ", entries: [.item(title: "小", action: {})]),
        ])

        #expect(menu.autoenablesItems == false)
        #expect(menu.items.allSatisfy { $0.isEnabled })
        #expect(menu.items[1].submenu?.autoenablesItems == false)
        #expect(menu.items[1].submenu?.items.allSatisfy { $0.isEnabled } == true)
    }
}
