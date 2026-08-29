import AppKit
import Foundation

/// 前面にあるアプリ名を取る。
///
/// アプリ名の取得にアクセシビリティ権限は要らない（ウィンドウ名を取ろうとすると要る）。
/// 「直前まで何をしていたか」をセリフに混ぜるためだけに使うので、名前で足りる。
public struct FrontmostAppMonitor: Sendable {

    public typealias Probe = @Sendable () -> String?

    private let probe: Probe

    public init(probe: @escaping Probe = FrontmostAppMonitor.systemFrontmostApp) {
        self.probe = probe
    }

    public func currentAppName() -> String? {
        probe()
    }

    public static let systemFrontmostApp: Probe = {
        MainActor.assumeIsolated {
            NSWorkspace.shared.frontmostApplication?.localizedName
        }
    }
}
