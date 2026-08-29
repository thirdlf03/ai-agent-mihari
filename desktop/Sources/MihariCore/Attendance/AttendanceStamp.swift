import Foundation

/// 在席を証明する1回分のスタンプ。
///
/// Touch ID(またはパスワード)の認証に成功した瞬間を記録する。`biometryTypeText` は
/// 認証にどの方式が使えたかを履歴に残すための表示用の値で、判定には使わない。
public struct AttendanceStamp: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let stampedAt: Date
    public let biometryTypeText: String

    public init(id: UUID = UUID(), stampedAt: Date, biometryTypeText: String) {
        self.id = id
        self.stampedAt = stampedAt
        self.biometryTypeText = biometryTypeText
    }
}
