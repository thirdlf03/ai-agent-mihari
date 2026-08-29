import Foundation

/// Codex Desktop の 4 つのステータスに対応する、ペットの外部向け状態。
enum PetStatus: String, CaseIterable {
    /// 作業中。
    case running
    /// 承認や入力を待っている。
    case needsInput
    /// 完了して未読がある。
    case ready
    /// 失敗・エラーで止まっている。
    case blocked

    /// このステータスのときに再生するアニメーション。
    /// 作業中は、行 7 `running` が足踏みに見えるため、集中して確認している行 8 `review` を使う。
    var animation: PetAnimation {
        switch self {
        case .running: return .review
        case .needsInput: return .waiting
        case .ready: return .jumping
        case .blocked: return .failed
        }
    }

    /// このステータスになったときに言うセリフの種類。
    var speechKind: PetSpeechLines.Kind {
        switch self {
        case .running: return .running
        case .needsInput: return .needsInput
        case .ready: return .ready
        case .blocked: return .blocked
        }
    }

    /// 1 周だけ再生して自動的に解除するステータスか。
    var isMomentary: Bool { self == .ready }
}
