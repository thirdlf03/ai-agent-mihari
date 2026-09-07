import Foundation

/// 仕事一覧の「未読完了」を覚えておく口。再起動後も未読が消えないようにする。
public protocol RoomJobReadStoring {
    /// その仕事を開いて読んだか。
    func isRead(_ jobID: String) -> Bool
    /// その仕事を読んだとして記録する。
    func markRead(_ jobID: String)
}

/// UserDefaults に読んだ仕事の ID を覚えておく実体。
public struct UserDefaultsRoomJobReadStore: RoomJobReadStoring {
    private let defaults: UserDefaults
    private let key = "room.readJobIDs"

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func isRead(_ jobID: String) -> Bool {
        defaults.stringArray(forKey: key)?.contains(jobID) ?? false
    }

    public func markRead(_ jobID: String) {
        var ids = defaults.stringArray(forKey: key) ?? []
        if !ids.contains(jobID) {
            ids.append(jobID)
        }
        defaults.set(ids, forKey: key)
    }
}
