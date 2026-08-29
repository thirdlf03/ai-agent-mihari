import CoreGraphics
import Foundation

/// Mac の無操作秒数を測る。
///
/// 入力監視の権限が無くても `secondsSinceLastEventType` は値を返す。
/// キーやマウスの「内容」は一切見ない。最後に何かが起きてからの経過時間だけを取る。
public struct MacIdleMonitor: Sendable {

    /// 無操作秒数を取る処理。テストから差し替えられるようにしている。
    public typealias Probe = @Sendable () -> TimeInterval

    private let probe: Probe

    public init(probe: @escaping Probe = MacIdleMonitor.systemIdleSeconds) {
        self.probe = probe
    }

    public func idleSeconds() -> TimeInterval {
        max(0, probe())
    }

    /// あらゆる入力イベントからの経過秒数。
    public static let systemIdleSeconds: Probe = {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .init(rawValue: ~0)!)
    }
}
