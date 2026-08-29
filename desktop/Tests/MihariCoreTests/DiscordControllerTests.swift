import Foundation
import Testing

@testable import MihariCore

@Suite("Discord の操作")
@MainActor
struct DiscordControllerTests {

    @Test("デーモンが動いていなければ状態は取れず、理由が残る")
    func withoutDaemon() async {
        let controller = DiscordController()
        await controller.refresh(using: nil)
        #expect(controller.status == nil)
        #expect(controller.lastError == DaemonError.notRunning.errorDescription)
    }

    @Test("デーモンが動いていなければ投稿は失敗として返る")
    func postWithoutDaemon() async {
        let controller = DiscordController()
        let posted = await controller.post(text: "やあ", using: nil)
        #expect(posted == false)
        #expect(controller.lastError == DaemonError.notRunning.errorDescription)
    }

    @Test("チャンネル取得もデーモンが要る")
    func channelsWithoutDaemon() async {
        let controller = DiscordController()
        await controller.refreshChannels(using: nil)
        #expect(controller.channels.isEmpty)
        #expect(controller.lastError == DaemonError.notRunning.errorDescription)
    }

    @Test("招待 URL が無いときは何をすればよいかを出す")
    func inviteWithoutURL() {
        let controller = DiscordController()
        controller.openInvite()
        #expect(controller.lastError?.contains("DISCORD_CLIENT_ID") == true)
    }
}
