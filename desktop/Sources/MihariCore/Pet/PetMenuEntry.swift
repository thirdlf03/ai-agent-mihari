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
                title: "仕事を頼む…",
                action: { actions.openJobRequest() }
            ),
            roomEntries(actions: actions),
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
            .item(
                title: "スクショに写り込む",
                isChecked: actions.isPhotobombEnabled,
                action: { actions.setPhotobombEnabled(!actions.isPhotobombEnabled) }
            ),
            .separator,
            .submenu(
                title: "デバッグ",
                entries: PetDebugMenuEntries.make(actions: actions, presenter: presenter)
            ),
        ]
    }

    /// 「作業部屋」サブメニュー。いま追っている仕事の状態と、追記・中断・成果物を開く操作を並べる。
    @MainActor
    private static func roomEntries<Actions: PetMenuActions>(actions: Actions) -> PetMenuEntry {
        guard let job = actions.roomJob else {
            return .item(
                title: "作業部屋(仕事なし)",
                action: { actions.openJobRequest() }
            )
        }
        var entries: [PetMenuEntry] = [
            .item(
                title: "状態: \(job.title) — \(job.status.label)",
                action: {}
            ),
            .item(
                title: "追記する…",
                action: { actions.followUpRoomJob() }
            ),
            .item(
                title: "中断する",
                action: { actions.cancelRoomJob() }
            ),
        ]
        if let latestText = job.latestText, !latestText.isEmpty {
            entries.append(
                .item(title: "進捗: \(latestText)", action: {})
            )
        }
        if let error = job.lastError {
            entries.append(
                .item(title: "配信エラー: \(error)", action: {})
            )
        }
        let openable = job.artifacts.filter {
            guard let scheme = $0.previewURL?.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        }
        if openable.isEmpty {
            entries.append(.item(title: "成果物なし", action: {}))
        } else {
            entries.append(.separator)
            for artifact in openable {
                let url = artifact.previewURL!
                entries.append(
                    .item(title: artifactTitle(artifact), action: { actions.openRoomArtifact(url) })
                )
            }
        }
        return .submenu(title: "作業部屋", entries: entries)
    }

    /// 成果物 1 件のメニュー名。種類が読めれば添える。
    private static func artifactTitle(_ artifact: RoomArtifact) -> String {
        if let kind = artifact.kind, !kind.isEmpty {
            return "成果物を開く: \(kind)"
        }
        return "成果物を開く"
    }
}
