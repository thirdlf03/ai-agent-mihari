import Foundation

/// 1 回の評価の記録。
///
/// 「なぜ撮られたのか」が後から分からないと、閾値を詰めようがないし、
/// 撮られた本人も納得できない。判断の根拠を必ず残す。
public struct DetectionLogEntry: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let at: Date
    public let state: DetectionState
    public let evidence: EvidenceKind
    public let reason: String
    /// 実際に起きたこと。撮れなかった・送れなかった場合はその理由。
    public let outcome: String

    public init(
        at: Date = Date(),
        state: DetectionState,
        evidence: EvidenceKind,
        reason: String,
        outcome: String
    ) {
        self.at = at
        self.state = state
        self.evidence = evidence
        self.reason = reason
        self.outcome = outcome
    }
}
