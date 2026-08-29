import SwiftUI

/// 常駐デーモンの状態と、経路が通っているかの確認用画面。
public struct DaemonView: View {
    @ObservedObject var controller: DaemonController

    public init(controller: DaemonController) {
        self.controller = controller
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                controls
                if let error = controller.lastError {
                    errorBox(error)
                }
                devicesSection
                eventsSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("デーモン").font(.title2).bold()
            Text("Discord Bot・セリフ生成・iPhone の取得はこの Python プロセスが受け持つ。アプリが終了すると一緒に落ちる。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Label(controller.state.label, systemImage: statusIcon)
                    .foregroundStyle(statusColor)
                Label(
                    controller.isStreamConnected ? "イベント購読中" : "イベント未接続",
                    systemImage: controller.isStreamConnected
                        ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
                )
                .foregroundStyle(controller.isStreamConnected ? Color.green : Color.secondary)
            }
            .font(.callout)
            .padding(.top, 2)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button("起動") { Task { await controller.start() } }
                .disabled(controller.isRunning)
            Button("停止") { controller.stop() }
                .disabled(!controller.isRunning)
            Button("再起動") { Task { await controller.restart() } }
            Divider().frame(height: 16)
            Button("iPhone を探す") { Task { await controller.refreshDevices() } }
                .disabled(!controller.isRunning)
            Button("テストイベントを流す") { Task { await controller.sendTestEvent() } }
                .disabled(!controller.isRunning)
            Spacer()
        }
    }

    private func errorBox(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("iPhone").font(.headline)
            if controller.devices.isEmpty {
                Text("まだ見つかっていない。USB で繋ぐか、一度ペアリング済みなら同じ Wi-Fi にいれば見つかる。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.devices) { device in
                    HStack(spacing: 8) {
                        Text(device.udid).font(.system(size: 11, design: .monospaced))
                        Text(device.connectionType)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                        if let host = device.host {
                            Text(host).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("受信したイベント").font(.headline)
            if controller.events.isEmpty {
                Text("まだ届いていない。「テストイベントを流す」で Python → アプリの経路を確認できる。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.events) { event in
                    HStack(alignment: .top, spacing: 8) {
                        Text(event.createdAt.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(event.name).font(.system(size: 11, design: .monospaced)).bold()
                        if !event.payload.isEmpty {
                            Text(event.payload.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusIcon: String {
        switch controller.state {
        case .running: return "checkmark.circle.fill"
        case .starting: return "clock.fill"
        case .failed: return "xmark.circle.fill"
        case .stopped: return "pause.circle.fill"
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .running: return .green
        case .starting: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        }
    }
}
