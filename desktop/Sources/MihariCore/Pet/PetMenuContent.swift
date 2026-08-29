import SwiftUI

/// メニューバーの「ペット」メニューの中身。
///
/// 並びは `PetMenuEntries` が 1 か所で決める。ここはそれを SwiftUI のメニュー項目として描くだけで、
/// 右クリックメニューは同じ並びから `PetContextMenu` が `NSMenu` を作る。
public struct PetMenuContent<Actions: PetMenuActions>: View {
    @ObservedObject public var actions: Actions
    public let pet: PetController

    public init(actions: Actions, pet: PetController) {
        self.actions = actions
        self.pet = pet
    }

    public var body: some View {
        PetMenuEntryList(entries: PetMenuEntries.make(actions: actions, pet: pet))
    }
}

/// `PetMenuEntry` の並びをメニュー項目として描く。サブメニューのために自分を入れ子にする。
private struct PetMenuEntryList: View {
    let entries: [PetMenuEntry]

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case .item(let title, let isChecked, let action):
                // チェックの有無をそのまま出すため、押されたら `action` を呼ぶだけの Toggle にする。
                Toggle(title, isOn: Binding(get: { isChecked }, set: { _ in action() }))
            case .submenu(let title, let entries):
                Menu(title) {
                    PetMenuEntryList(entries: entries)
                }
            case .separator:
                Divider()
            }
        }
    }
}
