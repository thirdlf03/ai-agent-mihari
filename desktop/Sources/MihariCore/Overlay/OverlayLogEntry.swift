import Foundation

/// オーバーレイが解除された理由。ログ表示と、テストでの検証に使う。
public enum OverlayDismissReason: Equatable, Sendable {
    /// 読み上げの推定所要時間が経過した(自動解除)。
    case speechFinished
    /// 上限秒数に達した(自動解除。最後の安全策)。
    case timeLimit
    /// Esc キーによる緊急解除。
    case escape
    /// 画面のボタンなど、呼び出し側からの明示的な解除。
    case manual

    /// ログに残す日本語の理由。
    public var label: String {
        switch self {
        case .speechFinished: return "読み上げ完了(推定)"
        case .timeLimit: return "上限秒数の経過"
        case .escape: return "Esc キーによる緊急解除"
        case .manual: return "手動解除"
        }
    }
}

/// 「試す」1 回分の実行ログ。画面の「直近の実行ログ」に出す。
public struct OverlayLogEntry: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let at: Date
    public let message: String

    public init(at: Date = Date(), message: String) {
        self.at = at
        self.message = message
    }
}
