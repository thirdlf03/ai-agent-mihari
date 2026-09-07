import AppKit
import SwiftUI

/// 操作中の常設表示の口。テストでは何もしないスタブに差し替える。
public protocol MacControlOperationIndicating: AnyObject, Sendable {
    /// 操作を始めた。画面上に「操作中」と停止ボタンを出す。
    @MainActor func show(summary: String, onStop: @escaping @Sendable () -> Void)
    /// 操作が終わった（成否を問わず）ので表示を畳む。
    @MainActor func hide()
}

/// 実機の常設表示。画面右上に浮かぶ小さなパネルで、停止ボタンも持つ。
@MainActor
public final class MacControlOperationPanelIndicator: MacControlOperationIndicating {

    fileprivate final class Model: ObservableObject {
        @Published var summary = ""
        var onStop: (@Sendable () -> Void)?
    }

    private let model = Model()
    private var panel: NSPanel?

    public init() {}

    public func show(summary: String, onStop: @escaping @Sendable () -> Void) {
        model.summary = summary
        model.onStop = onStop
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    public func hide() {
        model.onStop = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let content = IndicatorContentView(model: model)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 84),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: content)
        // メインディスプレイの右上。複数画面でも誰かが見られる場所に出したいので、
        // マウスがいる画面の右上に出す。
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(
                    x: frame.maxX - panel.frame.width - 24,
                    y: frame.maxY - panel.frame.height - 24
                )
            )
        }
        return panel
    }
}

private struct IndicatorContentView: View {
    @ObservedObject var model: MacControlOperationPanelIndicator.Model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "cursorarrow.motionlines")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("みはりちゃんが Mac を操作中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.summary)
                    .font(.callout).bold()
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("停止") {
                model.onStop?()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.orange.opacity(0.6), lineWidth: 1.5)
        )
    }
}
