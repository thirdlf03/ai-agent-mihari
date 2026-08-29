import AppKit

/// `PetMenuEntry` の並びから AppKit の `NSMenu` を作る。
///
/// 右クリックメニューを SwiftUI の `.contextMenu` で出すと、ペットのコマ送りでビューが
/// 作り直されるたびにメニューも作り直され、サブメニューが開いた先から閉じてしまう。
/// NSMenu ならビューの再評価と関係なく開いたままになる。
public enum PetContextMenu {

    /// 並びどおりの `NSMenu` を作る。サブメニューも同じ手順で入れ子にする。
    @MainActor
    public static func makeMenu(_ entries: [PetMenuEntry]) -> NSMenu {
        let menu = NSMenu()
        // キーウィンドウにならないパネルから出すので、AppKit の自動での有効・無効判定には任せない。
        menu.autoenablesItems = false
        for entry in entries {
            menu.addItem(makeItem(entry))
        }
        return menu
    }

    @MainActor
    private static func makeItem(_ entry: PetMenuEntry) -> NSMenuItem {
        switch entry {
        case .separator:
            return .separator()
        case .item(let title, let isChecked, let action):
            let item = NSMenuItem(
                title: title,
                action: #selector(PetMenuActionTarget.invokeAction(_:)),
                keyEquivalent: ""
            )
            let target = PetMenuActionTarget(action: action)
            item.target = target
            // NSMenuItem は target を弱参照で持つので、項目自身にも持たせて生かしておく。
            item.representedObject = target
            item.state = isChecked ? .on : .off
            return item
        case .submenu(let title, let entries):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = makeMenu(entries)
            return item
        }
    }
}

/// メニュー項目のクロージャを AppKit のセレクタ呼び出しに橋渡しする。
@MainActor
private final class PetMenuActionTarget: NSObject {
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    // `perform` という名前だと `NSObject.perform(_:)` の方に解決されてしまうので、別の名前にしている。
    @objc func invokeAction(_ sender: Any?) {
        action()
    }
}
