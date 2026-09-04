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
    /// 「実際に進める」で投げられた操作。
    private(set) var detectionSteps: [DetectionDebugStep] = []

    func startWatching() {}
    func stopWatching() {}
    func stampAttendance() {}
    func startBreak() {}
    func endBreak() {}
    func openDiscordSettings() {}
    func openJobRequest() { jobRequestOpens += 1 }
    func openPermissions() {}
    func toggleStatusPanel() {}
    func setPhotobombEnabled(_ enabled: Bool) { isPhotobombEnabled = enabled }
    func setVoiceMode(_ mode: VoiceMode) { voiceMode = mode }
    func setFocusStreakInterval(_ seconds: TimeInterval) { focusStreakIntervalSeconds = seconds }
    func setFastThresholds(_ enabled: Bool) { isFastThresholds = enabled }
    func replayFocusStreak() { focusStreakReplays += 1 }
    func runDetectionStep(_ step: DetectionDebugStep) { detectionSteps.append(step) }
}
