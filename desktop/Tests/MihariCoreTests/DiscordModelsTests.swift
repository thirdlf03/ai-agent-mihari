import Foundation
import Testing

@testable import MihariCore

@Suite("Discord の状態")
struct DiscordStatusTests {

    private func decode(_ json: String) throws -> DiscordStatus {
        try JSONDecoder().decode(DiscordStatus.self, from: Data(json.utf8))
    }

    private let ready = """
        {"token_configured":true,"client_id_configured":true,"missing":[],"bot_ready":true,
         "last_error":null,"invite_url":"https://discord.com/oauth2/authorize?client_id=1",
         "selection":{"guild_id":1,"channel_id":2,"guild_name":"サーバ","channel_name":"general"},
         "schedule":{"watching":false,"scheduled":null}}
        """

    @Test("投稿できる状態を読む")
    func decodesReadyState() throws {
        let status = try decode(ready)
        #expect(status.isReadyToPost)
        #expect(status.summary == "投稿できる")
        #expect(status.selection?.channelName == "general")
    }

    @Test("足りない環境変数を名指しする")
    func namesMissingEnvironment() throws {
        // 「なぜ投稿できないのか」が分からないと直しようがない。
        let status = try decode(
            """
            {"token_configured":false,"client_id_configured":false,
             "missing":["DISCORD_BOT_TOKEN","DISCORD_CLIENT_ID"],"bot_ready":false,
             "last_error":null,"invite_url":null,"selection":null,
             "schedule":{"watching":false,"scheduled":null}}
            """
        )
        #expect(status.isReadyToPost == false)
        #expect(status.summary.contains("DISCORD_BOT_TOKEN"))
        #expect(status.summary.contains("DISCORD_CLIENT_ID"))
    }

    @Test("チャンネル未選択なら次にやることを出す")
    func promptsChannelSelection() throws {
        let status = try decode(
            """
            {"token_configured":true,"client_id_configured":true,"missing":[],"bot_ready":true,
             "last_error":null,"invite_url":"https://x","selection":null,
             "schedule":{"watching":false,"scheduled":null}}
            """
        )
        #expect(status.isReadyToPost == false)
        #expect(status.summary.contains("チャンネル"))
    }

    @Test("Bot 側のエラーがあればそれを優先して出す")
    func surfacesBotError() throws {
        let status = try decode(
            """
            {"token_configured":true,"client_id_configured":true,"missing":[],"bot_ready":false,
             "last_error":"DISCORD_BOT_TOKEN が正しくない","invite_url":"https://x","selection":null,
             "schedule":{"watching":false,"scheduled":null}}
            """
        )
        #expect(status.summary == "DISCORD_BOT_TOKEN が正しくない")
    }
}

@Suite("投稿先チャンネル")
struct DiscordChannelTests {

    @Test("サーバ名とチャンネル名を並べて出す")
    func displayName() {
        let channel = DiscordChannel(guildID: 1, guildName: "作業部屋", channelID: 2, channelName: "sabori")
        #expect(channel.displayName == "作業部屋 / #sabori")
    }

    @Test("名前が無ければ ID で代用する")
    func fallsBackToIDs() {
        // 保存済みの選択には名前が入っていないことがある。
        #expect(DiscordChannel(guildID: 1, channelID: 2).displayName == "サーバ 1 / 2")
    }

    @Test("名前が欠けた JSON も読める")
    func decodesWithoutNames() throws {
        let channel = try JSONDecoder().decode(
            DiscordChannel.self,
            from: Data(#"{"guild_id":1,"channel_id":2}"#.utf8)
        )
        #expect(channel.guildName.isEmpty)
        #expect(channel.channelID == 2)
    }
}

@Suite("監視の予約状況")
struct WatchScheduleTests {

    private func decode(_ json: String) throws -> WatchSchedule {
        try JSONDecoder().decode(WatchSchedule.self, from: Data(json.utf8))
    }

    @Test("監視中はそう出す")
    func watching() throws {
        #expect(try decode(#"{"watching":true,"scheduled":null}"#).summary == "監視中")
    }

    @Test("予約があれば時刻を出す")
    func scheduled() throws {
        let schedule = try decode(
            #"{"watching":false,"scheduled":{"at":"2026-08-29T19:00:00","requested_by":"kyiku"}}"#
        )
        #expect(schedule.summary.contains("19:00"))
    }

    @Test("どちらでもなければ監視していないと出す")
    func idle() throws {
        #expect(try decode(#"{"watching":false,"scheduled":null}"#).summary == "監視していない")
    }
}
