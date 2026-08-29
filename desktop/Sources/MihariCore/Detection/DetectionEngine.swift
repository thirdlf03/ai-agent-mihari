import Foundation
import SwiftUI
import os

/// サボりを見張って、決まったことを実行する。
///
/// 判定そのものは `DetectionJudge`(純粋関数)が持つ。ここがやるのは
/// 材料を集めて渡し、返ってきた結論どおりに撮る・喋る・送るところまで。
///
/// **どのアクションが失敗しても評価ループは止めない。** カメラが使えない、
/// VOICEVOX が起動していない、Discord のトークンが無い、はどれも起こりうる。
/// 1 つ転んだせいで見張り自体が死ぬのが一番まずい。
@MainActor
public final class DetectionEngine: ObservableObject {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "detection")

    /// 何秒ごとに評価するか。
    public static let tickSeconds: TimeInterval = 5

    /// 画面に残す記録の件数。
    public static let logHistoryLimit = 50

    @Published public private(set) var isWatching = false
    @Published public private(set) var state: DetectionState = .normal
    @Published public private(set) var lastSignals: DetectionSignals?
    @Published public private(set) var log: [DetectionLogEntry] = []
    @Published public var thresholds: DetectionThresholds = .default

    private let idleMonitor: MacIdleMonitor
    private let frontmostMonitor: FrontmostAppMonitor
    private let capture: CaptureService
    private let attendance: AttendanceModel?
    private var loop: Task<Void, Never>?
    private var lastEvidenceAt: Date?

    /// 実行部。テストからはここを差し替えて、実際に撮らず送らずに筋道だけを確かめる。
    public struct Actions: Sendable {
        public var captureMacPhoto: @Sendable () async -> Data?
        public var captureIPhoneScreenshot: @Sendable () async -> Data?
        public var speak: @Sendable (SpeechRequest) async -> String?
        public var interrupt: @Sendable (SpeechRequest) async -> Void
        public var post: @Sendable (String, Data?, String) async -> Bool
        public var classify: @Sendable (Data) async -> SpeechRequest.VisionLabel

        public init(
            captureMacPhoto: @escaping @Sendable () async -> Data? = { nil },
            captureIPhoneScreenshot: @escaping @Sendable () async -> Data? = { nil },
            speak: @escaping @Sendable (SpeechRequest) async -> String? = { _ in nil },
            interrupt: @escaping @Sendable (SpeechRequest) async -> Void = { _ in },
            post: @escaping @Sendable (String, Data?, String) async -> Bool = { _, _, _ in false },
            classify: @escaping @Sendable (Data) async -> SpeechRequest.VisionLabel = { _ in .unknown }
        ) {
            self.captureMacPhoto = captureMacPhoto
            self.captureIPhoneScreenshot = captureIPhoneScreenshot
            self.speak = speak
            self.interrupt = interrupt
            self.post = post
            self.classify = classify
        }
    }

    public var actions = Actions()

    /// iPhone の様子。SSE で流れてくる値を外から入れてもらう。
    public var iphoneState: SpeechRequest.IPhoneState = .unreachable

    /// 判定のたびにペットへ渡す通知口。
    /// エンジンはペットの中身を知らないので、渡す形だけ決めて外で繋ぐ。
    public var onEvent: ((PetEvent) -> Void)?

    public init(
        idleMonitor: MacIdleMonitor = MacIdleMonitor(),
        frontmostMonitor: FrontmostAppMonitor = FrontmostAppMonitor(),
        capture: CaptureService = CaptureService(),
        attendance: AttendanceModel? = nil
    ) {
        self.idleMonitor = idleMonitor
        self.frontmostMonitor = frontmostMonitor
        self.capture = capture
        self.attendance = attendance
    }

    public func start() {
        guard !isWatching else { return }
        isWatching = true
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.evaluate()
                try? await Task.sleep(for: .seconds(Self.tickSeconds))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        isWatching = false
        state = .normal
    }

    /// いまの材料を集める。
    public func currentSignals() -> DetectionSignals {
        DetectionSignals(
            macIdleSeconds: idleMonitor.idleSeconds(),
            iphone: iphoneState,
            secondsSinceStamp: attendance?.secondsSinceLastStamp,
            frontmostApp: frontmostMonitor.currentAppName()
        )
    }

    /// 1 回だけ評価して実行する。ループからも、画面の「いま評価する」ボタンからも呼ぶ。
    @discardableResult
    public func evaluate(now: Date = Date()) async -> DetectionDecision {
        let signals = currentSignals()
        lastSignals = signals

        let judge = DetectionJudge(thresholds: thresholds)
        let decision = judge.decide(
            signals,
            secondsSinceLastEvidence: lastEvidenceAt.map { now.timeIntervalSince($0) }
        )
        state = decision.state

        guard decision.state != .normal else { return decision }

        let outcome = await perform(decision, signals: signals, now: now)
        record(decision, outcome: outcome, at: now)
        return decision
    }

    // MARK: - 実行

    private func perform(
        _ decision: DetectionDecision,
        signals: DetectionSignals,
        now: Date
    ) async -> String {
        var notes: [String] = []

        let evidence = await collectEvidence(decision.evidence)
        if decision.evidence != .none {
            lastEvidenceAt = now
            notes.append(evidence == nil ? "証拠を取れなかった" : "証拠を取った")
        }

        var label = SpeechRequest.VisionLabel.unknown
        if let evidence, decision.evidence == .macCamera {
            // 写真に写っているのが「寝ている/よそ見/不在」のどれかを見立てる。
            // 判定そのものには使わず、セリフと Discord の文面に添えるだけ。
            label = await actions.classify(evidence)
        }
        let request = makeRequest(signals: signals, decision: decision, label: label)

        var line = ""
        if decision.shouldInterrupt {
            await actions.interrupt(request)
            line = decision.reason
            notes.append("音楽を止めて聞かせた")
        } else if decision.shouldSpeak {
            if let spoken = await actions.speak(request) {
                line = spoken
            } else {
                line = decision.reason
                notes.append("喋れなかった")
            }
        }
        notifyPet(decision, label: label, line: line)

        if let evidence {
            let sent = await actions.post(decision.reason, evidence, filename(for: decision.evidence))
            notes.append(sent ? "Discord に送った" : "Discord に送れなかった")
        }

        return notes.isEmpty ? "声をかけた" : notes.joined(separator: " / ")
    }

    /// ペットに状態とセリフを渡す。ペット側の実装は知らない。
    private func notifyPet(_ decision: DetectionDecision, label: SpeechRequest.VisionLabel, line: String) {
        onEvent?(
            PetEvent(
                state: petState(decision.state),
                escalationStage: petStage(decision),
                line: line,
                visionLabel: petLabel(label),
                prompt: nil
            )
        )
    }

    private func petState(_ state: DetectionState) -> SaboriState {
        switch state {
        case .normal: return .normal
        case .suspected: return .suspected
        case .confirmed: return .confirmed
        }
    }

    private func petStage(_ decision: DetectionDecision) -> Int {
        switch (decision.state, decision.evidence) {
        case (.suspected, _): return 1
        case (.confirmed, .none): return 2
        case (.confirmed, _): return 3
        default: return 0
        }
    }

    private func petLabel(_ label: SpeechRequest.VisionLabel) -> VisionLabel {
        switch label {
        case .sleeping: return .asleep
        case .lookingAway: return .lookingAway
        case .absent: return .absent
        case .unknown: return .none
        }
    }

    private func collectEvidence(_ kind: EvidenceKind) async -> Data? {
        switch kind {
        case .macCamera: return await actions.captureMacPhoto()
        case .iphoneScreenshot: return await actions.captureIPhoneScreenshot()
        case .none: return nil
        }
    }

    private func makeRequest(
        signals: DetectionSignals,
        decision: DetectionDecision,
        label: SpeechRequest.VisionLabel
    ) -> SpeechRequest {
        SpeechRequest(
            idleSeconds: Int(signals.macIdleSeconds),
            escalation: escalation(for: decision),
            frontmostApp: signals.frontmostApp,
            iphone: signals.iphone,
            vision: label
        )
    }

    private func escalation(for decision: DetectionDecision) -> SpeechRequest.Escalation {
        switch (decision.state, decision.evidence) {
        case (.suspected, _): return .nudge
        case (.confirmed, .none): return .warn
        case (.confirmed, _): return .expose
        case (.normal, _): return .nudge
        }
    }

    private func filename(for kind: EvidenceKind) -> String {
        switch kind {
        case .macCamera: return "camera.png"
        case .iphoneScreenshot: return "iphone.png"
        case .none: return "evidence.png"
        }
    }

    private func record(_ decision: DetectionDecision, outcome: String, at now: Date) {
        Self.logger.info(
            "\(decision.state.rawValue, privacy: .public): \(decision.reason, privacy: .public) → \(outcome, privacy: .public)"
        )
        log.insert(
            DetectionLogEntry(
                at: now,
                state: decision.state,
                evidence: decision.evidence,
                reason: decision.reason,
                outcome: outcome
            ),
            at: 0
        )
        if log.count > Self.logHistoryLimit {
            log.removeLast(log.count - Self.logHistoryLimit)
        }
    }
}
