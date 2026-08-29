import AppKit
import SwiftUI
import os

/// 全画面オーバーレイの表示 / 解除を担う層。`NSWindow` の生成と
/// `NSApplication.presentationOptions` の変更はここに閉じ込め、`OverlayModel` からは
/// プロトコル越しにしか触らせない。テストではスタブに差し替え、実際に全画面表示を発生させない。
@MainActor
public protocol OverlayWindowPresenting: AnyObject {
    /// いま表示中かどうか。
    var isPresenting: Bool { get }

    /// すべての画面に 1 枚ずつオーバーレイを出す。`onEscape` は Esc キーで呼ばれる。
    func present(text: String, onEscape: @escaping () -> Void)

    /// ウィンドウを畳み、`presentationOptions` を必ず空集合に戻す。
    func dismiss()
}

/// `NSWindow(level: .screenSaver)` + `NSApplication.presentationOptions` による実装。
///
/// `NSScreen.screens` を全部回って画面ごとに 1 枚ウィンドウを出すことで、
/// マルチディスプレイでも死角ができないようにする。
@MainActor
public final class ScreenSaverOverlayPresenter: OverlayWindowPresenting {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "overlay.window")

    private var windows: [OverlayWindow] = []

    public init() {
        assert(
            OverlayPresentationPolicy.invalidCombinationReasons(in: OverlayPresentationPolicy.sermonOptions).isEmpty,
            "sermonOptions が無効な組み合わせになっている"
        )
    }

    public var isPresenting: Bool { !windows.isEmpty }

    public func present(text: String, onEscape: @escaping () -> Void) {
        guard !isPresenting else { return }

        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            Self.logger.error("NSScreen.screens が空のため、オーバーレイを表示できない")
            return
        }

        windows = screens.map { screen in
            makeWindow(for: screen, text: text, onEscape: onEscape)
        }

        NSApp.activate(ignoringOtherApps: true)
        for window in windows {
            window.orderFrontRegardless()
        }
        windows.first?.makeKey()

        NSApp.presentationOptions = OverlayPresentationPolicy.sermonOptions
        Self.logger.info("オーバーレイを \(self.windows.count, privacy: .public) 画面に表示した")
    }

    public func dismiss() {
        guard isPresenting else { return }

        for window in windows {
            window.onEscape = nil
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()

        // 解除時は必ず素の状態に戻す。ここを飛ばすと Dock / メニューバーが隠れたままになる。
        NSApp.presentationOptions = OverlayPresentationPolicy.dismissed
        Self.logger.info("オーバーレイを解除し、presentationOptions を戻した")
    }

    private func makeWindow(for screen: NSScreen, text: String, onEscape: @escaping () -> Void) -> OverlayWindow {
        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: SermonOverlayContentView(text: text))
        window.setFrame(screen.frame, display: true)
        window.onEscape = onEscape
        return window
    }
}

/// オーバーレイの見た目。全画面に同じものを 1 枚ずつ出す。
struct SermonOverlayContentView: View {
    let text: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
            VStack(spacing: 24) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.system(size: 48))
                Text(text)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 80)
                Text("Esc キーで今すぐ解除できる")
                    .font(.system(size: 16))
                    .opacity(0.7)
            }
            .foregroundStyle(.white)
        }
        .ignoresSafeArea()
    }
}
