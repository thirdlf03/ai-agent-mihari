import AppKit
import SwiftUI

/// §5-2 会話 UI。テキスト履歴・接続状態・再接続・終了。
@MainActor
public final class VoiceCallWindowController {
    public static let shared = VoiceCallWindowController()

    private var window: NSWindow?
    private var controller: VoiceConversationController?
    /// `window.delegate` は弱参照なので、ここで保持する。
    private var windowDelegate: VoiceCallWindowDelegate?

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
        // 赤ボタンで窓を閉じられても会話が残らないよう、閉鎖で stop を呼ぶ。
        let delegate = VoiceCallWindowDelegate()
        delegate.onWillClose = { [weak controller] in
            controller?.stop()
        }
        window.delegate = delegate
        windowDelegate = delegate
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

/// 会話窓の閉鎖をコントローラへ伝えるだけのデリゲート。
@MainActor
private final class VoiceCallWindowDelegate: NSObject, NSWindowDelegate {
    var onWillClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onWillClose?()
    }
}

struct VoiceCallView: View {
    @ObservedObject var controller: VoiceConversationController
    @State private var answerDrafts: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            messageList
            if !controller.pendingQuestions.isEmpty {
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
        VStack(alignment: .leading, spacing: 12) {
            Text("仕事からの質問（\(controller.pendingQuestions.count) 件）")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(controller.pendingQuestions) { question in
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.prompt)
                        .font(.subheadline)
                        .textSelection(.enabled)
                    if !question.choices.isEmpty {
                        Text(question.choices.joined(separator: " / "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        TextField("回答を入力", text: answerBinding(for: question.questionID))
                            .textFieldStyle(.roundedBorder)
                        Button("送信") {
                            let draft = answerDrafts[question.questionID] ?? ""
                            controller.submitPendingQuestionAnswer(draft, questionID: question.questionID)
                            answerDrafts[question.questionID] = ""
                        }
                        .disabled(
                            (answerDrafts[question.questionID] ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
    }

    private func answerBinding(for questionID: String) -> Binding<String> {
        Binding(
            get: { answerDrafts[questionID] ?? "" },
            set: { answerDrafts[questionID] = $0 }
        )
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
