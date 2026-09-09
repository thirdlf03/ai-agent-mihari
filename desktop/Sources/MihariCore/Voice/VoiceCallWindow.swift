import AppKit
import SwiftUI

/// §5-2 会話 UI。テキスト履歴・接続状態・再接続・終了。
@MainActor
public final class VoiceCallWindowController {
    public static let shared = VoiceCallWindowController()

    private var window: NSWindow?
    private var controller: VoiceConversationController?

    public init() {}

    /// 会話窓を開く（または前面へ）。
    public func show(controller: VoiceConversationController) {
        self.controller = controller
        let view = VoiceCallView(controller: controller)
        if let window {
            window.contentViewController = NSHostingController(rootView: AnyView(view))
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "みはりちゃんと会話"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: AnyView(view))
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// 窓を閉じる（会話は止めない）。
    public func closeWindow() {
        window?.orderOut(nil)
    }

    var isVisibleForTesting: Bool {
        window?.isVisible ?? false
    }
}

struct VoiceCallView: View {
    @ObservedObject var controller: VoiceConversationController
    @State private var answerDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            messageList
            if controller.pendingQuestion != nil {
                Divider()
                questionBar
            }
            Divider()
            controlBar
        }
        .frame(minWidth: 360, minHeight: 400)
    }

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(controller.statusText)
                .font(.subheadline)
                .lineLimit(2)
            Spacer()
            if controller.isMicLive {
                Label("マイク", systemImage: "mic.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if controller.isActive {
                Label("マイク停止中", systemImage: "mic.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusColor: Color {
        switch controller.connectionState {
        case .idle: return .gray
        case .connecting, .reconnecting: return .yellow
        case .ready: return .green
        case .error: return .red
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(controller.messages) { message in
                        VoiceMessageRow(message: message)
                            .id(message.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: controller.messages.count) { _, _ in
                if let last = controller.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var questionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let question = controller.pendingQuestion {
                Text("仕事からの質問")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(question.prompt)
                    .font(.subheadline)
                    .textSelection(.enabled)
                HStack {
                    TextField("回答を入力", text: $answerDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("送信") {
                        controller.submitPendingQuestionAnswer(answerDraft)
                        answerDraft = ""
                    }
                    .disabled(answerDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
    }

    private var controlBar: some View {
        HStack {
            Button("再接続") {
                controller.reconnect()
            }
            .disabled(!controller.isActive)

            Button("画面見て") {
                controller.captureAndSendScreen()
            }
            .disabled(!controller.isActive || controller.connectionState != .ready)

            Spacer()

            Button("会話を終了") {
                controller.stop()
                VoiceCallWindowController.shared.closeWindow()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }
}

private struct VoiceMessageRow: View {
    let message: VoiceConversationMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(roleLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let thumbnail = message.imageThumbnailPNG,
                    let image = NSImage(data: thumbnail)
                {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 200, maxHeight: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Text(message.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(bubbleColor)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return "あなた"
        case .assistant: return "みはり"
        case .system: return "システム"
        }
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user: return Color.accentColor.opacity(0.15)
        case .assistant: return Color.secondary.opacity(0.12)
        case .system: return Color.orange.opacity(0.1)
        }
    }
}
