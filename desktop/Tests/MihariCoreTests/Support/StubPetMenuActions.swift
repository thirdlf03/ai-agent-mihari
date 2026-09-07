import Foundation

@testable import MihariCore

/// メニューの並びを組み立てるためだけの `PetMenuActions`。押された項目を記録する。
@MainActor
final class StubPetMenuActions: ObservableObject, PetMenuActions {
    var isWatching = false
    var isOnBreak = false
    var isStatusPanelVisible = false
    var isPhotobombEnabled = true
    var voiceMode: VoiceMode = .bundled
    var focusStreakIntervalSeconds: TimeInterval = 900
    var isFastThresholds = false
    /// 「集中継続のセリフを再現」が押された回数。
    private(set) var focusStreakReplays = 0
    /// 「仕事を頼む…」が押された回数。
    private(set) var jobRequestOpens = 0
    /// 仕事一覧が出せるか。テストからの差し込み口。
    var supportsRoomJobList = true
    /// 「仕事一覧を開く…」が押された回数。
    private(set) var roomListOpens = 0
    /// いま追っている仕事。テストからの差し込み口。
    var roomJob: RoomJobSummary?
    /// 「詳細を開く…」が押された回数。
    private(set) var roomDetailOpens = 0
    /// 「追記する…」が押された回数。
    private(set) var roomFollowUps = 0
    /// 「中断する」が押された回数。
    private(set) var roomCancels = 0
    /// 「成果物を開く」で渡された URL。
    private(set) var roomArtifactURLs: [URL] = []
    /// メニューから承認した記憶の候補 ID。
    private(set) var approvedMemoryIDs: [String] = []
    /// メニューから却下した記憶の候補 ID。
    private(set) var rejectedMemoryIDs: [String] = []
    /// メニューから戻した成果物の version。
    private(set) var rolledBackVersions: [String] = []
    /// 「実際に進める」で投げられた操作。
    private(set) var detectionSteps: [DetectionDebugStep] = []

    func startWatching() {}
    func stopWatching() {}
    func stampAttendance() {}
    func startBreak() {}
    func endBreak() {}
    func openDiscordSettings() {}
    func openJobRequest() { jobRequestOpens += 1 }
    func openRoomJobList() { roomListOpens += 1 }
    func openRoomJobDetail() { roomDetailOpens += 1 }
    func followUpRoomJob() { roomFollowUps += 1 }
    func cancelRoomJob() { roomCancels += 1 }
    func openRoomArtifact(_ url: URL) { roomArtifactURLs.append(url) }
    func approveRoomMemory(candidateID: String) { approvedMemoryIDs.append(candidateID) }
    func rejectRoomMemory(candidateID: String) { rejectedMemoryIDs.append(candidateID) }
    func rollbackRoomArtifact(version: String) { rolledBackVersions.append(version) }
    func openPermissions() {}
    func toggleStatusPanel() {}
    func setPhotobombEnabled(_ enabled: Bool) { isPhotobombEnabled = enabled }
    func setVoiceMode(_ mode: VoiceMode) { voiceMode = mode }
    func setFocusStreakInterval(_ seconds: TimeInterval) { focusStreakIntervalSeconds = seconds }
    func setFastThresholds(_ enabled: Bool) { isFastThresholds = enabled }
    func replayFocusStreak() { focusStreakReplays += 1 }
    func runDetectionStep(_ step: DetectionDebugStep) { detectionSteps.append(step) }
}
