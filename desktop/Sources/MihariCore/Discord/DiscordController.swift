import AppKit
import Foundation
import SwiftUI
import os

/// Discord への投稿と、監視予約の操作。
///
/// 投稿できないことは検知を止める理由にならないので、失敗はすべて `lastError` に残して返すだけにする。
@MainActor
public final class DiscordController: ObservableObject {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "discord")

    @Published public private(set) var status: DiscordStatus?
    @Published public private(set) var channels: [DiscordChannel] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastPostedMessageID: Int?
    /// 直近の操作が成功したときの一言。失敗は `lastError` に出す。
    @Published public private(set) var lastNotice: String?

    public init() {}

    /// Bot の状態を取り直す。
    public func refresh(using client: DaemonClient?) async {
        guard let client else {
            status = nil
            lastError = DaemonError.notRunning.errorDescription
            return
        }
        do {
            status = try await client.discordStatus()
            lastError = nil
        } catch {
            status = nil
            lastError = describe(error)
        }
    }

    /// 招待 URL をブラウザで開く。
    public func openInvite() {
        guard let raw = status?.inviteURL, let url = URL(string: raw) else {
            lastError = "招待 URL がない。bridge/.env の DISCORD_CLIENT_ID を設定する"
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// 投稿できるチャンネルを取り直す。
    public func refreshChannels(using client: DaemonClient?) async {
        guard let client else {
            lastError = DaemonError.notRunning.errorDescription
            return
        }
        do {
            channels = try await client.discordChannels().channels
            lastError = channels.isEmpty ? "投稿できるチャンネルが見つからない。Bot をサーバに入れたか確認する" : nil
        } catch {
            channels = []
            lastError = describe(error)
        }
    }

    /// 投稿先を決める。
    public func select(_ channel: DiscordChannel, using client: DaemonClient?) async {
        guard let client else {
            lastError = DaemonError.notRunning.errorDescription
            return
        }
        do {
            try await client.selectDiscordChannel(channel)
            await refresh(using: client)
        } catch {
            lastError = describe(error)
        }
    }

    /// 証拠を投稿する。投稿できたら `true`。
    @discardableResult
    public func post(
        text: String,
        image: Data? = nil,
        filename: String = "evidence.png",
        using client: DaemonClient?
    ) async -> Bool {
        guard let client else {
            lastError = DaemonError.notRunning.errorDescription
            return false
        }
        do {
            let result = try await client.postToDiscord(text: text, image: image, filename: filename)
            lastPostedMessageID = result.messageID
            lastError = nil
            return true
        } catch {
            // 晒せなくても検知は続く。原因だけ残す。
            lastError = describe(error)
            Self.logger.error("Discord へ投稿できなかった: \(self.lastError ?? "", privacy: .public)")
            return false
        }
    }

    /// 証拠を晒すときに呼びつける相手を決める。数字だけの ID を渡す。空文字ならメンションを外す。
    public func setMention(_ userID: String?, using client: DaemonClient?) async {
        guard let client else {
            lastError = DaemonError.notRunning.errorDescription
            return
        }
        let trimmed = userID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        do {
            let result = try await client.setDiscordMention(value)
            lastError = nil
            lastNotice = result.mentionUserID.map { "メンション先を \($0) にした" } ?? "メンションを外した"
            await refresh(using: client)
        } catch {
            lastNotice = nil
            lastError = describe(error)
        }
    }

    /// メンション付きのテスト投稿をさせる。
    public func postTest(using client: DaemonClient?) async {
        guard let client else {
            lastError = DaemonError.notRunning.errorDescription
            return
        }
        do {
            let result = try await client.postDiscordTest()
            lastPostedMessageID = result.messageID
            lastError = nil
            lastNotice = "テスト投稿を送った (message id: \(result.messageID))"
        } catch {
            lastNotice = nil
            lastError = describe(error)
            Self.logger.error("Discord へテスト投稿できなかった: \(self.lastError ?? "", privacy: .public)")
        }
    }

    /// 監視の開始を予約する。`time` が `nil` ならすぐ始める。
    public func setSchedule(at time: String?, using client: DaemonClient?) async {
        guard let client else {
            lastError = DaemonError.notRunning.errorDescription
            return
        }
        do {
            try await client.setWatchSchedule(at: time)
            await refresh(using: client)
        } catch {
            lastError = describe(error)
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? DaemonError)?.errorDescription ?? error.localizedDescription
    }
}
