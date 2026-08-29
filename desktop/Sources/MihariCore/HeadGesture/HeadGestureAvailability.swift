import Foundation

/// AirPods の首振り入力が今使えるかどうか。
public enum HeadGestureAvailability: Sendable, Equatable {
    /// 使える。
    case available
    /// 使えない。理由はそのまま人に見せられる文言で持つ。
    case unavailable(reason: String)

    public var isAvailable: Bool {
        self == .available
    }

    /// 使えない理由。使えるときは `nil`。
    public var reason: String? {
        if case .unavailable(let reason) = self {
            return reason
        }
        return nil
    }
}
