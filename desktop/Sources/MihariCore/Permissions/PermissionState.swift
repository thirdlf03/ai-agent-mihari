import Foundation

/// 権限の許可状態。
///
/// `undetermined` は「まだユーザーに聞いていない」と「照会する API がなく判別できない」の両方を表す。
/// macOS の TCC は前者と後者を区別できない権限があるため、まとめて 1 つにしている。
public enum PermissionGrant: String, Sendable, Equatable {
    case granted
    case denied
    case undetermined
}

/// 1 つの権限の現在の状態と、画面に出す説明文。
public struct PermissionState: Sendable, Equatable {
    public let grant: PermissionGrant

    /// 実際に呼んだ API が何を返したかをそのまま見せる文字列。
    /// 許可が下りない原因を切り分けるとき、生の値が見えないと調べようがないため残している。
    public let detail: String

    public init(grant: PermissionGrant, detail: String) {
        self.grant = grant
        self.detail = detail
    }

    /// まだ一度も照会していない状態。
    public static let unchecked = PermissionState(
        grant: .undetermined,
        detail: "未チェック"
    )
}
