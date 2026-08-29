import AppKit
import SwiftUI

/// 状態パネルを出す / しまうの管理と、その状態の保存。
///
/// パネルの中身(`StatusPanelView`)は呼び出し側が渡す。ここは表示の有無だけを持つ。
@MainActor
final class StatusPanelController {

    /// 表示の有無を覚えておくキー。
    static let visibilityKey = "statusPanel.isVisible"

    /// いま出しているか。
    private(set) var isVisible: Bool

    private let defaults: UserDefaults
    private var window: StatusPanelWindow?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 検証用の起動(`MIHARI_DEBUG_UI=1`)では、保存値にかかわらず最初から出す。
        // 状態を見たくて付ける環境変数なので、いちいちメニューから出させない。
        self.isVisible =
            Self.isForced || (defaults.object(forKey: Self.visibilityKey) as? Bool ?? false)
    }

    /// 起動時に、覚えていたとおりに出す。ここでは保存し直さない。
    func restore<Content: View>(@ViewBuilder content: () -> Content) {
        guard isVisible else { return }
        show(content: content())
    }

    /// 表示を切り替える。切り替えた結果は次の起動にも引き継ぐ。
    func toggle<Content: View>(@ViewBuilder content: () -> Content) {
        isVisible.toggle()
        defaults.set(isVisible, forKey: Self.visibilityKey)
        if isVisible {
            show(content: content())
        } else {
            window?.orderOut(nil)
        }
    }

    private func show<Content: View>(content: Content) {
        let panel = window ?? StatusPanelWindow(defaults: defaults, content: content)
        window = panel
        panel.orderFrontRegardless()
    }

    private static var isForced: Bool {
        ProcessInfo.processInfo.environment[AppCoordinator.debugUIEnvironmentKey] == "1"
    }
}
