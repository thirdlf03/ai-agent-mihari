import Foundation

/// ペットメニューの 1 項目。右クリック(NSMenu)とメニューバー(SwiftUI)で同じ並びを出すための共通表現。
public enum PetMenuEntry {
    /// 押せる項目。`isChecked` が true ならチェックを付ける。
    case item(title: String, isChecked: Bool = false, action: @MainActor () -> Void)
    /// 入れ子のメニュー。
    case submenu(title: String, entries: [PetMenuEntry])
    /// 区切り線。
    case separator
}

/// ペットメニューの並びを 1 か所で決める。
///
/// 右クリック(`PetContextMenu`)もメニューバー(`PetMenuContent`)もここから作るので、
/// 項目を足すときはここだけを直せばよい。
public enum PetMenuEntries {

    /// メニューの並びを組み立てる。呼ぶたびに、そのときの状態でチェックと文言を決める。
    @MainActor
    public static func make<Actions: PetMenuActions>(
        actions: Actions,
        presenter: LivePetPresenter
    ) -> [PetMenuEntry] {
        let pet = presenter.controller
        return [
            .item(
                title: actions.isWatching ? "監視を止める" : "監視を再開する",
                action: {
                    if actions.isWatching {
                        actions.stopWatching()
                    } else {
                        actions.startWatching()
                    }
                }
            ),
            .item(
                title: "在席スタンプを押す",
                action: { actions.stampAttendance() }
            ),
            .item(
                title: actions.isOnBreak ? "休憩を終える" : "休憩する(15 分)",
                action: {
                    if actions.isOnBreak {
                        actions.endBreak()
                    } else {
                        actions.startBreak()
                    }
                }
            ),
            .separator,
            .item(
                title: "Discord 設定…",
                action: { actions.openDiscordSettings() }
            ),
            .item(
                title: "権限の確認…",
                action: { actions.openPermissions() }
            ),
            .separator,
            .submenu(
                title: "サイズ",
                entries: PetScale.allCases.map { item -> PetMenuEntry in
                    .item(
                        title: item.label,
                        isChecked: pet.scale == item.rawValue,
                        action: { pet.setScale(item.rawValue) }
                    )
                }
            ),
            .item(
                title: "声を出す",
                isChecked: pet.isVoiceEnabled,
                action: { pet.setVoiceEnabled(!pet.isVoiceEnabled) }
            ),
            .item(
                title: "状態パネルを表示",
                isChecked: actions.isStatusPanelVisible,
                action: { actions.toggleStatusPanel() }
            ),
            .separator,
            .submenu(
                title: "デバッグ",
                entries: PetDebugMenuEntries.make(presenter: presenter)
            ),
        ]
    }
}
