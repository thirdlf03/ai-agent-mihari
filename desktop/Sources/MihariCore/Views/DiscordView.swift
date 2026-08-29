import SwiftUI

/// Discord Bot の設定と、投稿の確認画面。
public struct DiscordView: View {
    @ObservedObject var discord: DiscordController
    @ObservedObject var daemon: DaemonController

    @State private var scheduleTime = "19:00"
    @State private var testMessage = "テスト投稿です。"

    public init(discord: DiscordController, daemon: DaemonController) {
        self.discord = discord
        self.daemon = daemon
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                setupSteps
                channelSection
                scheduleSection
                postSection
                if let error = discord.lastError {
                    errorBox(error)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await discord.refresh(using: daemon.connectedClient) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Discord").font(.title2).bold()
            Text("証拠の投稿も、監視の指示も Discord Bot 経由で行う。Bot は Mac の上で動くので、Mac が落ちている間はコマンドが効かない。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let status = discord.status {
                Label(
                    status.summary,
                    systemImage: status.isReadyToPost ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(status.isReadyToPost ? Color.green : Color.orange)
            } else {
                Label("状態を取得できていない", systemImage: "questionmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button("状態を取り直す") { Task { await discord.refresh(using: daemon.connectedClient) } }
                .controlSize(.small)
                .padding(.top, 2)
        }
    }

    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("セットアップ").font(.headline)
            step(1, "Discord Developer Portal でアプリを作る", done: discord.status?.clientIDConfigured == true)
            step(2, "APPLICATION ID と Bot トークンを bridge/.env に書く", done: discord.status?.tokenConfigured == true)
            step(3, "招待 URL から自分のサーバに Bot を入れる", done: discord.status?.botReady == true)
            step(4, "投稿先チャンネルを選ぶ", done: discord.status?.selection != nil)

            HStack(spacing: 10) {
                Button("招待 URL を開く") { discord.openInvite() }
                    .disabled(discord.status?.inviteURL == nil)
                if let missing = discord.status?.missing, !missing.isEmpty {
                    Text("bridge/.env に \(missing.joined(separator: " / ")) が必要")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func step(_ number: Int, _ text: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
            Text(text).font(.callout).foregroundStyle(done ? .secondary : .primary)
            Spacer()
        }
    }

    private var channelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("投稿先").font(.headline)
                Spacer()
                Button("チャンネルを探す") { Task { await discord.refreshChannels(using: daemon.connectedClient) } }
                    .controlSize(.small)
                    .disabled(discord.status?.botReady != true)
            }

            if let selected = discord.status?.selection {
                Label(selected.displayName, systemImage: "number")
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            if discord.channels.isEmpty {
                Text("まだ探していない。Bot をサーバに入れてから「チャンネルを探す」を押す。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(discord.channels) { channel in
                    HStack {
                        Text(channel.displayName).font(.callout)
                        Spacer()
                        Button("ここに送る") {
                            Task { await discord.select(channel, using: daemon.connectedClient) }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("監視の予約").font(.headline)
            Text(discord.status?.schedule.summary ?? "不明")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                TextField("HH:MM", text: $scheduleTime).frame(width: 90)
                Button("この時刻から") { Task { await discord.setSchedule(at: scheduleTime, using: daemon.connectedClient) } }
                Button("いますぐ") { Task { await discord.setSchedule(at: nil, using: daemon.connectedClient) } }
                Spacer()
            }
            Text("Discord からは /watch start · /watch at HH:MM · /watch stop · /watch status で操作できる。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var postSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("テスト投稿").font(.headline)
            HStack(spacing: 10) {
                TextField("送る文面", text: $testMessage)
                Button("送る") {
                    Task { await discord.post(text: testMessage, using: daemon.connectedClient) }
                }
                .disabled(discord.status?.isReadyToPost != true)
            }
            if let id = discord.lastPostedMessageID {
                Text("送信済み (message id: \(id))").font(.caption).foregroundStyle(.green)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
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
}
