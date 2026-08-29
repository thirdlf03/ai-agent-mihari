import Foundation
import Testing

@testable import MihariCore

/// 実際に `device-bridge serve` を起動して、アプリ側の経路が端まで通ることを確かめる。
///
/// uv と同期済みの `bridge/` が要る。用意されていない環境では丸ごとスキップする。
enum DaemonAvailability {
    /// uv と同期済みの bridge/ が揃っているか。
    /// 自分自身を参照する条件をスイート内に置くとマクロが循環するため、外に出している。
    static var isReady: Bool {
        let locator = DaemonLocator()
        return (try? locator.uvPath()) != nil && (try? locator.bridgeDirectory()) != nil
    }
}

@Suite("デーモンとの結合", .enabled(if: DaemonAvailability.isReady))
@MainActor
struct DaemonIntegrationTests {

    /// uv の起動を含むので待ちは長めに取る。
    private static let timeout: Duration = .seconds(60)

    @Test("起動 → イベント購読 → テストイベント受信 → 停止 まで通る")
    func endToEnd() async throws {
        let controller = DaemonController()
        defer { controller.stop() }

        await controller.start()

        guard case .running(let port, let pid) = controller.state else {
            Issue.record("デーモンが起動しなかった: \(controller.state.label)")
            return
        }
        #expect(port > 0)
        #expect(pid > 0)

        // SSE がつながるまで待つ。接続直後に connected イベントが 1 件届く。
        try await waitUntil("イベント購読が始まる", controller) { controller.isStreamConnected }
        try await waitUntil("connected が届く", controller) { controller.events.contains { $0.name == "connected" } }

        await controller.sendTestEvent()
        try await waitUntil("test.ping が届く", controller) { controller.events.contains { $0.name == "test.ping" } }

        let ping = try #require(controller.events.first { $0.name == "test.ping" })
        #expect(ping.payload["from"] == "app")
        #expect(controller.lastError == nil)

        controller.stop()
        #expect(controller.state == .stopped)
        #expect(controller.isStreamConnected == false)
    }

    @Test("デーモンが動いていなければ、要求は落ちずにエラーとして残る")
    func requestsWithoutDaemonFail() async {
        let controller = DaemonController()

        await controller.refreshDevices()
        #expect(controller.devices.isEmpty)
        #expect(controller.lastError == DaemonError.notRunning.errorDescription)

        await controller.sendTestEvent()
        #expect(controller.lastError == DaemonError.notRunning.errorDescription)
    }

    private func waitUntil(_ what: String, _ controller: DaemonController, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: Self.timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record(
            """
            待っても条件を満たさなかった: \(what)
            state=\(controller.state.label) stream=\(controller.isStreamConnected)             events=\(controller.events.map(\.name)) lastError=\(controller.lastError ?? "なし")
            """
        )
    }
}
