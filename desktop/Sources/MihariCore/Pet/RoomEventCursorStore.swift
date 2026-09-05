import Foundation

/// 仕事ごとの再開点(Last-Event-ID のカーソル)の保存。
///
/// アプリが落ちても、同じ部屋に繋ぎ直したときは最後に見たイベントの続きから配信を
/// 再開できる。トークンや URL は保存しない。
public protocol RoomJobCursorStoring {
    /// 指定した仕事の最後のイベント ID。無ければ `nil`。
    func cursor(for jobID: String) -> String?
    /// カーソルを書き換える。`nil` で消す。
    func setCursor(_ eventID: String?, for jobID: String)
    /// 最後に追った仕事の ID。再起動時に優先して拾う目印。
    var lastJobID: String? { get set }
}

/// UserDefaults に保存する実体。キーは仕事単位なので、並んで走る複数の仕事を区別できる。
public final class UserDefaultsRoomJobCursorStore: RoomJobCursorStoring {

    /// 最後に追った仕事の ID を覚えるキー。アプリ再起動時に照会する目印。
    public static let lastJobIDKey = "room.lastJobID"
    /// 仕事ごとのカーソルのキー。`room.eventCursor.<jobID>`。
    public static func cursorKey(for jobID: String) -> String {
        "room.eventCursor.\(jobID)"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func cursor(for jobID: String) -> String? {
        defaults.string(forKey: Self.cursorKey(for: jobID))
    }

    public func setCursor(_ eventID: String?, for jobID: String) {
        if let eventID {
            defaults.set(eventID, forKey: Self.cursorKey(for: jobID))
        } else {
            defaults.removeObject(forKey: Self.cursorKey(for: jobID))
        }
    }

    /// 最後に追った仕事の ID。無ければ `nil`。
    public var lastJobID: String? {
        get { defaults.string(forKey: Self.lastJobIDKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.lastJobIDKey)
            } else {
                defaults.removeObject(forKey: Self.lastJobIDKey)
            }
        }
    }
}
