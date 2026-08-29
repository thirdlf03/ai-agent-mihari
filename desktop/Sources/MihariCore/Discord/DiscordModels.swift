import Foundation

/// Bot が使える状態かと、いま何が足りないか。
public struct DiscordStatus: Decodable, Equatable, Sendable {
    public let tokenConfigured: Bool
    public let clientIDConfigured: Bool
    /// 足りていない環境変数の名前。
    public let missing: [String]
    public let botReady: Bool
    public let lastError: String?
    /// サーバに Bot を入れるための URL。`DISCORD_CLIENT_ID` が無ければ `nil`。
    public let inviteURL: String?
    public let selection: DiscordChannel?
    public let schedule: WatchSchedule

    enum CodingKeys: String, CodingKey {
        case tokenConfigured = "token_configured"
        case clientIDConfigured = "client_id_configured"
        case missing
        case botReady = "bot_ready"
        case lastError = "last_error"
        case inviteURL = "invite_url"
        case selection
        case schedule
    }

    /// 画面に出す、いま何をすればよいかの一言。
    public var summary: String {
        if !missing.isEmpty {
            return "bridge/.env に \(missing.joined(separator: " と ")) を設定する"
        }
        if let lastError {
            return lastError
        }
        if !botReady {
            return "Bot を起動中…"
        }
        if selection == nil {
            return "招待 URL からサーバに入れて、投稿先チャンネルを選ぶ"
        }
        return "投稿できる"
    }

    public var isReadyToPost: Bool {
        botReady && selection != nil
    }
}

/// 投稿先の候補、または選択済みのチャンネル。
public struct DiscordChannel: Decodable, Equatable, Sendable, Identifiable {
    public let guildID: Int
    public let guildName: String
    public let channelID: Int
    public let channelName: String

    public var id: Int { channelID }

    enum CodingKeys: String, CodingKey {
        case guildID = "guild_id"
        case guildName = "guild_name"
        case channelID = "channel_id"
        case channelName = "channel_name"
    }

    public init(guildID: Int, guildName: String = "", channelID: Int, channelName: String = "") {
        self.guildID = guildID
        self.guildName = guildName
        self.channelID = channelID
        self.channelName = channelName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guildID = try container.decode(Int.self, forKey: .guildID)
        channelID = try container.decode(Int.self, forKey: .channelID)
        // 選択済みチャンネルの保存には名前が入っていないことがある。
        guildName = try container.decodeIfPresent(String.self, forKey: .guildName) ?? ""
        channelName = try container.decodeIfPresent(String.self, forKey: .channelName) ?? ""
    }

    /// 画面に出す表示名。
    public var displayName: String {
        let guild = guildName.isEmpty ? "サーバ \(guildID)" : guildName
        let channel = channelName.isEmpty ? "\(channelID)" : "#\(channelName)"
        return "\(guild) / \(channel)"
    }
}

public struct DiscordChannelList: Decodable, Equatable, Sendable {
    public let channels: [DiscordChannel]
}

/// 監視の予約状況。
public struct WatchSchedule: Decodable, Equatable, Sendable {
    public let watching: Bool
    public let scheduled: ScheduledWatch?

    public struct ScheduledWatch: Decodable, Equatable, Sendable {
        public let at: String
        public let requestedBy: String

        enum CodingKeys: String, CodingKey {
            case at
            case requestedBy = "requested_by"
        }
    }

    public var summary: String {
        if watching { return "監視中" }
        if let scheduled { return "\(scheduled.at) から監視予定" }
        return "監視していない"
    }
}

public struct DiscordPostResult: Decodable, Equatable, Sendable {
    public let posted: Bool
    public let messageID: Int

    enum CodingKeys: String, CodingKey {
        case posted
        case messageID = "message_id"
    }
}

/// チャンネルを選んだあとの応答。
public struct DiscordChannelSelection: Decodable, Equatable, Sendable {
    public let selection: DiscordChannel
}
