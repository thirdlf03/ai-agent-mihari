import Foundation

@testable import MihariCore

/// メニューの並びを組み立てるためだけの `PetMenuActions`。押された項目を記録する。
@MainActor
final class StubPetMenuActions: ObservableObject, PetMenuActions {
    var isWatching = false
    var isOnBreak = false
    var isStatusPanelVisible = false
    var voiceMode: VoiceMode = .bundled
    var focusStreakIntervalSeconds: TimeInterval = 900
    /// 「集中継続のセリフを再現」が押された回数。
    private(set) var focusStreakReplays = 0
    /// 「実際に進める」で投げられた操作。
    private(set) var detectionSteps: [DetectionDebugStep] = []

    func startWatching() {}
    func stopWatching() {}
    func stampAttendance() {}
    func startBreak() {}
    func endBreak() {}
    func openDiscordSettings() {}
    func openPermissions() {}
    func toggleStatusPanel() {}
    func setVoiceMode(_ mode: VoiceMode) { voiceMode = mode }
    func setFocusStreakInterval(_ seconds: TimeInterval) { focusStreakIntervalSeconds = seconds }
    func replayFocusStreak() { focusStreakReplays += 1 }
    func runDetectionStep(_ step: DetectionDebugStep) { detectionSteps.append(step) }
}
