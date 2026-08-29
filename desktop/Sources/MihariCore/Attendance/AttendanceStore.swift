import Foundation
import os

/// スタンプ履歴の永続化。
///
/// `UserDefaults` に JSON でまとめて保存する。DB を持ち込むほどの量ではないため、
/// `PermissionsModel` と同じく保存先を注入可能にしてテストできるようにしている。
///
/// `UserDefaults` はスレッドセーフだが `Sendable` 適合を宣言していないため、`@unchecked` で受ける。
public struct AttendanceStore: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "attendance-store")

    /// 保存する履歴の上限件数。超えた分は古いものから捨てる。
    public static let historyLimit = 200

    static let storageKey = "com.thirdlf03.mihari.attendanceStamps"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 保存済みの履歴を新しい順で返す。
    public func load() -> [AttendanceStamp] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        do {
            let stamps = try JSONDecoder().decode([AttendanceStamp].self, from: data)
            return Self.sortedNewestFirst(stamps)
        } catch {
            Self.logger.error("スタンプ履歴のデコードに失敗した: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// 新しいスタンプを加えて保存する。上限を超えた分は古いものから捨てる。
    ///
    /// - Returns: 保存後の履歴(新しい順)。呼び出し側はこれをそのまま画面の状態にできる。
    @discardableResult
    public func append(_ stamp: AttendanceStamp, to existing: [AttendanceStamp]) -> [AttendanceStamp] {
        let merged = Self.sortedNewestFirst(existing + [stamp])
        let trimmed = Array(merged.prefix(Self.historyLimit))
        save(trimmed)
        return trimmed
    }

    private func save(_ stamps: [AttendanceStamp]) {
        do {
            let data = try JSONEncoder().encode(stamps)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            Self.logger.error("スタンプ履歴のエンコードに失敗した: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func sortedNewestFirst(_ stamps: [AttendanceStamp]) -> [AttendanceStamp] {
        stamps.sorted { $0.stampedAt > $1.stampedAt }
    }
}
