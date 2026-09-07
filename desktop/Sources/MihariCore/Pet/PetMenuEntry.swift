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
        // 旧バックエンドでは「仕事一覧」を出さない。
        let jobListEntries: [PetMenuEntry] =
            actions.supportsRoomJobList
            ? [
                .item(
                    title: "仕事一覧を開く…",
                    action: { actions.openRoomJobList() }
                )
            ]
            : []
        let head: [PetMenuEntry] = [
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
        ]
        let tail: [PetMenuEntry] = [
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
        return head + jobListEntries + tail
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
                title: "詳細を開く…",
                action: { actions.openRoomJobDetail() }
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
        if job.pendingMemoryCount > 0 {
            entries.append(.separator)
            for candidate in job.memoryCandidates.filter(\.isPending) {
                let clip = clipText(candidate.content)
                entries.append(
                    .item(
                        title: "承認: \(clip)",
                        action: { actions.approveRoomMemory(candidateID: candidate.candidateID) }
                    )
                )
                entries.append(
                    .item(
                        title: "却下: \(clip)",
                        action: { actions.rejectRoomMemory(candidateID: candidate.candidateID) }
                    )
                )
            }
        }
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
        if let opError = job.operationError {
            entries.append(
                .item(title: "操作エラー: \(opError)", action: {})
            )
        }
        let artifacts = job.artifacts
        if artifacts.isEmpty {
            entries.append(.item(title: "成果物なし", action: {}))
        } else {
            entries.append(.separator)
            for artifact in artifacts {
                let label = artifactTitle(artifact)
                if artifact.isPublic,
                    let url = artifact.previewURL,
                    let scheme = url.scheme?.lowercased(),
                    scheme == "http" || scheme == "https"
                {
                    entries.append(.item(title: label, action: { actions.openRoomArtifact(url) }))
                } else if artifact.isPublic {
                    // 非 http の URL（旧データ）はメニューに載せない。
                    continue
                } else {
                    // 非公開は認証付きのアプリ内プレビュー（詳細パネルから）。
                    entries.append(
                        .item(
                            title: privateArtifactTitle(artifact),
                            action: { actions.openRoomJobDetail() }
                        )
                    )
                }
                if let version = artifact.version, !version.isEmpty {
                    entries.append(
                        .item(
                            title: "v\(version) を再公開",
                            action: { actions.rollbackRoomArtifact(version: version) }
                        )
                    )
                }
            }
        }
        let tempOpenable = job.tempDeploys.compactMap(\.previewURL).filter { url in
            let scheme = url.scheme?.lowercased()
            return scheme == "http" || scheme == "https"
        }
        if !tempOpenable.isEmpty {
            entries.append(.separator)
            for url in tempOpenable {
                entries.append(
                    .item(title: "一時デプロイを開く", action: { actions.openRoomArtifact(url) })
                )
            }
        }
        return .submenu(title: "作業部屋", entries: entries)
    }

    /// 成果物 1 件のメニュー名。version があれば添える。
    private static func artifactTitle(_ artifact: RoomArtifact) -> String {
        if let version = artifact.version, !version.isEmpty {
            return "v\(version) を開く"
        }
        if let kind = artifact.kind, !kind.isEmpty {
            return "成果物を開く: \(kind)"
        }
        return "成果物を開く"
    }

    /// 非公開の版のメニュー名（アプリ内で認証付きプレビューする案内）。
    private static func privateArtifactTitle(_ artifact: RoomArtifact) -> String {
        if let version = artifact.version, !version.isEmpty {
            return "v\(version) をプレビュー（非公開）"
        }
        return "成果物をプレビュー（非公開）"
    }

    /// メニュー用に本文を 1 行・数十文字に潰す。
    private static func clipText(_ text: String, limit: Int = 24) -> String {
        let oneLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        if oneLine.count <= limit { return String(oneLine) }
        return String(oneLine.prefix(limit - 1)) + "…"
    }
}
