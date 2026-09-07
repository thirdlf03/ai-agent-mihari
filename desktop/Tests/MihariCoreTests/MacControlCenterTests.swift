import AppKit
import Foundation
import Testing

@testable import MihariCore

/// Mac 側の取りまとめ（接続・許可・操作・取り消し・再接続）を、差し替えの
/// ソケット / 実行部 / 許可ダイアログで確かめる。実機の CGEvent は一切打たない。
@Suite("Mac control の取りまとめ")
@MainActor
struct MacControlCenterTests {

    // MARK: - 差し替え

    /// テストが feed で流し込んだフレームを返し、送られたフレームを覚えるソケット。
    private final class ScriptedSocket: MacControlSocket, @unchecked Sendable {
        private let stream: AsyncStream<String>
        private var iterator: AsyncStream<String>.Iterator
        private let continuation: AsyncStream<String>.Continuation
        private let lock = NSLock()
        private var _sent: [String] = []
        private(set) var closed = false

        init() {
            var continuation: AsyncStream<String>.Continuation!
            let stream = AsyncStream { continuation = $0 }
            self.stream = stream
            self.iterator = stream.makeAsyncIterator()
            self.continuation = continuation
        }

        func feed(_ text: String) { continuation.yield(text) }
        func finish() { continuation.finish() }

        func send(_ text: String) async throws {
            lock.withLock { _sent.append(text) }
        }

        func receive() async throws -> String? {
            await iterator.next()
        }

        func close() async {
            closed = true
            continuation.finish()
        }

        var sent: [String] {
            lock.withLock { _sent }
        }
    }

    private final class ScriptedSocketFactory: MacControlSocketFactory, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [ScriptedSocket] = []
        private var _madeCount = 0

        func queue(_ socket: ScriptedSocket) {
            lock.lock()
            pending.append(socket)
            lock.unlock()
        }

        func makeSocket(endpoint: MacControlEndpoint) async throws -> any MacControlSocket {
            lock.withLock {
                _madeCount += 1
                if pending.isEmpty {
                    return ScriptedSocket()
                }
                return pending.removeFirst()
            }
        }

        var madeCount: Int {
            lock.withLock { _madeCount }
        }
    }

    private final class ScriptedOperator: MacControlOperating, @unchecked Sendable {
        private let lock = NSLock()
        private var _received: [MacControlOpFrame] = []
        var handler: (@Sendable (MacControlOpFrame) async throws -> MacOpExecutionResult)?

        func execute(op: MacControlOpFrame) async throws -> MacOpExecutionResult {
            lock.withLock { _received.append(op) }
            if let handler {
                return try await handler(op)
            }
            return .makeSuccess(["ok": true])
        }

        var received: [MacControlOpFrame] {
            lock.withLock { _received }
        }
    }

    private final class ScriptedDecider: MacControlPermissionDeciding, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [MacControlRequest] = []
        var decision: MacControlWire.Decision = .allow

        func decide(request: MacControlRequest) async -> MacControlWire.Decision {
            lock.withLock { _requests.append(request) }
            return decision
        }

        var requests: [MacControlRequest] {
            lock.withLock { _requests }
        }
    }

    private struct ScriptedDisplayListing: MacControlDisplayListing {
        let displays: [MacDisplayInfo]
        func currentDisplays() -> [MacDisplayInfo] { displays }
    }

    /// 表示の呼び出しを覚えるスタブ。
    private final class ScriptedIndicator: MacControlOperationIndicating, @unchecked Sendable {
        private let lock = NSLock()
        private var _shown: [String] = []
        private var _hides = 0
        var onStop: (@Sendable () -> Void)?

        func show(summary: String, onStop: @escaping @Sendable () -> Void) {
            lock.withLock {
                _shown.append(summary)
                self.onStop = onStop
            }
        }

        func hide() {
            lock.withLock {
                _hides += 1
                self.onStop = nil
            }
        }

        var shown: [String] {
            lock.withLock { _shown }
        }

        var hides: Int {
            lock.withLock { _hides }
        }
    }

    // MARK: - 部品

    private let displays = [
        MacDisplayInfo(
            displayID: "1",
            name: "Color LCD",
            widthPX: 2880,
            heightPX: 1800,
            scale: 2.0,
            bounds: MacRect(x: 0, y: 0, width: 1440, height: 900),
            layoutToken: "tok-abc"
        )
    ]

    private func makeDependencies(
        factory: ScriptedSocketFactory,
        operator: ScriptedOperator,
        decider: ScriptedDecider
    ) -> MacControlCenter.Dependencies {
        MacControlCenter.Dependencies(
            endpoint: MacControlEndpoint(
                baseURL: URL(string: "http://127.0.0.1:8787")!,
                token: "secret"
            ),
            identity: MacControlIdentity(
                deviceID: "mac-test",
                hostname: "test-mac",
                appVersion: "1.0",
                osVersion: "macOS 15"
            ),
            factory: factory,
            operator: `operator`,
            decider: decider,
            displayListing: ScriptedDisplayListing(displays: displays)
        )
    }

    private func sentType(_ sent: [String]) -> String? {
        guard let last = sent.last,
            let object = try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any]
        else {
            return nil
        }
        return object["type"] as? String
    }

    private func sentTypes(_ sent: [String]) -> [String] {
        sent.compactMap { text in
            guard let data = text.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }
            return object["type"] as? String
        }
    }

    /// state フレームの event だけを並べる。
    private func stateEvents(_ sent: [String]) -> [String] {
        sent.compactMap { text in
            guard let data = text.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["type"] as? String == "state"
            else {
                return nil
            }
            return object["event"] as? String
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 8,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 接続済みの center を作る。ファクトリへ socket を 1 本預けて hello_ack を返す。
    private func makeConnected(
        socket: ScriptedSocket,
        factory: ScriptedSocketFactory,
        operator: ScriptedOperator = ScriptedOperator(),
        decider: ScriptedDecider = ScriptedDecider()
    ) async -> MacControlCenter {
        factory.queue(socket)
        let center = MacControlCenter(deps: makeDependencies(factory: factory, operator: `operator`, decider: decider))
        center.start()
        // hello が送られるのを待つ。
        await waitUntil { !socket.sent.isEmpty }
        socket.feed(#"{"type":"hello_ack","device_id":"mac-test","protocol":1}"#)
        await waitUntil { center.isConnected }
        return center
    }

    // MARK: - テスト

    @Test("hello が送られ、hello_ack で接続になる")
    func helloFlow() async {
        let socket = ScriptedSocket()
        let factory = ScriptedSocketFactory()
        let center = await makeConnected(socket: socket, factory: factory)
        #expect(center.isConnected)
        let hello = socket.sent.first ?? ""
        let object = try? JSONSerialization.jsonObject(with: Data(hello.utf8)) as? [String: Any]
        #expect(object?["type"] as? String == "hello")
        #expect(object?["device_id"] as? String == "mac-test")
        let wireDisplays = object?["displays"] as? [[String: Any]]
        #expect(wireDisplays?.first?["display_id"] as? String == "1")
        center.stop()
    }

    @Test("ping に pong で返す")
    func pingPong() async {
        let socket = ScriptedSocket()
        let factory = ScriptedSocketFactory()
        let center = await makeConnected(socket: socket, factory: factory)
        socket.feed(#"{"type":"ping","ts":"2024-01-01T00:00:00Z"}"#)
        await waitUntil { socket.sent.contains { $0.contains("\"pong\"") } }
        #expect(socket.sent.last?.contains("\"pong\"") ?? false)
        center.stop()
    }

    @Test("control.request には人間の確認を挟んで答える（allow）")
    func permissionAllow() async {
        let socket = ScriptedSocket()
        let factory = ScriptedSocketFactory()
        let decider = ScriptedDecider()
        decider.decision = .allow
        let center = await makeConnected(socket: socket, factory: factory, decider: decider)
        socket.feed(
            #"{"type":"control.request","request_id":"r1","job_id":"job-1","run_id":"run-1","job_title":"画面を触って","scope":"whole_mac","note":"この依頼の間…"}"#
        )
        await waitUntil { !decider.requests.isEmpty }
        #expect(decider.requests.first?.jobID == "job-1")
        await waitUntil { socket.sent.contains { $0.contains("\"control.decision\"") } }
        let decision = socket.sent.last ?? ""
        #expect(decision.contains("\"decision\":\"allow\""))
        #expect(decision.contains("\"request_id\":\"r1\""))
        center.stop()
    }

    @Test("既定は拒否（deny）として答える")
    func permissionDenyByDefault() async {
        let socket = ScriptedSocket()
        let factory = ScriptedSocketFactory()
        let decider = ScriptedDecider()
        decider.decision = .deny
        let center = await makeConnected(socket: socket, factory: factory, decider: decider)
        socket.feed(
            #"{"type":"control.request","request_id":"r1","job_id":"job-1","run_id":"run-1","job_title":"画面を触って","scope":"whole_mac","note":"…"}"#
        )
        await waitUntil { socket.sent.contains { $0.contains("\"control.decision\"") } }
        #expect(socket.sent.last?.contains("\"decision\":\"deny\"") ?? false)
        center.stop()
    }

    @Test("op を 1 本実行して op.result を返す（撮影）")
    func opCapture() async {
        let socket = ScriptedSocket()
        let factory = ScriptedSocketFactory()
        let executor = ScriptedOperator()
        executor.handler = { op in
            .makeSuccess(
                [
                    "display_id": op.displayID ?? "1",
                    "width_px": 2880,
                    "height_px": 1800,
                    "scale": 2.0,
                    "bounds": ["x": 0, "y": 0, "width": 1440, "height": 900],
                    "layout_token": "tok-abc",
                    "image_base64": "aGk=",
                ]
            )
        }
        let center = await makeConnected(socket: socket, factory: factory, operator: executor)
        socket.feed(
            #"{"type":"op","op_id":"op-1","run_id":"run-1","job_id":"job-1","kind":"capture","params":{},"expected":null}"#
        )
        await waitUntil { executor.received.count == 1 }
        #expect(executor.received.first?.kind == .capture)
        await waitUntil { socket.sent.contains { $0.contains("\"op.result\"") } }
        let result = socket.sent.last ?? ""
        #expect(result.contains("\"op_id\":\"op-1\""))
        #expect(result.contains("\"ok\":true"))
        #expect(result.contains("\"image_base64\":\"aGk=\""))
        center.stop()
    }

    @Test("cancel_run は実行中の操作を止めて、結果不明のまま送らない")
    func cancelRunCancelsActiveOp() async {
        let socket = ScriptedSocket()
        let factory = ScriptedSocketFactory()
        let executor = ScriptedOperator()
        // type_text はキャンセルまで待ち続ける。キャンセルされると CancellationError が投げられる。
        executor.handler = { op in
            // キャンセルされるまで待つ。
            try await Task.sleep(for: .seconds(30))
            return .makeSuccess(["ok": true])
        }
        let center = await makeConnected(socket: socket, factory: factory, operator: executor)
        socket.feed(
            #"{"type":"op","op_id":"op-9","run_id":"run-1","job_id":"job-1","kind":"type_text","params":{"text":"ひらがな"}}"#
        )
        await waitUntil { executor.received.count == 1 }
        socket.feed(#"{"type":"cancel_run","run_id":"run-1","job_id":"job-1","reason":"user cancelled"}"#)
        await waitUntil { socket.sent.contains { $0.contains("\"op.result\"") } }
        let result = socket.sent.last ?? ""
        #expect(result.contains("\"ok\":false"))
        #expect(result.contains("\"canceled\""))
        center.stop()
    }

    @Test("切断すると張り直して、また hello を送る")
    func reconnectAfterDrop() async {
        let socket1 = ScriptedSocket()
        let socket2 = ScriptedSocket()
        let factory = ScriptedSocketFactory()
        factory.queue(socket1)
        factory.queue(socket2)
        let center = MacControlCenter(
            deps: makeDependencies(factory: factory, operator: ScriptedOperator(), decider: ScriptedDecider())
        )
        center.start()
        // 1 本目で接続。
        await waitUntil { !socket1.sent.isEmpty }
        socket1.feed(#"{"type":"hello_ack","device_id":"mac-test","protocol":1}"#)
        await waitUntil { center.isConnected }
        // 1 本目を切る → バックオフのあと 2 本目で張り直す。
        socket1.finish()
        await waitUntil { factory.madeCount >= 2 }
        await waitUntil { !socket2.sent.isEmpty }
        socket2.feed(#"{"type":"hello_ack","device_id":"mac-test","protocol":1}"#)
        await waitUntil { center.isConnected }
        let hello2 = socket2.sent.first ?? ""
        #expect(hello2.contains("\"hello\""))
        center.stop()
    }

    @Test("ロック / アンロックを state として部屋へ伝える")
    func lockUnlockSendsState() async {
        let socket = ScriptedSocket()
        let factory = ScriptedSocketFactory()
        let center = await makeConnected(socket: socket, factory: factory)
        center.sendState(.lock)
        await waitUntil { stateEvents(socket.sent).contains("lock") }
        #expect(stateEvents(socket.sent).last == "lock")
        center.sendStateAfterUnlock()
        await waitUntil { sentTypes(socket.sent).contains("displays") }
        // アンロックでは state(unlock) と displays の両方を送る。
        #expect(stateEvents(socket.sent).contains("unlock"))
        #expect(sentTypes(socket.sent).contains("displays"))
        center.stop()
    }

    @Test("操作中は常設表示を出し、終わったら畳む")
    func indicatorShownWhileOperating() async {
        let socket = ScriptedSocket()
        let factory = ScriptedSocketFactory()
        let center = await makeConnected(socket: socket, factory: factory)
        let indicator = ScriptedIndicator()
        center.operationIndicator = indicator
        socket.feed(
            #"{"type":"op","op_id":"op-3","run_id":"run-1","job_id":"job-1","kind":"click","params":{"display_id":"1","x":10,"y":20},"expected":null}"#
        )
        await waitUntil { indicator.shown.count == 1 }
        #expect(indicator.shown.first?.contains("click") ?? false)
        await waitUntil { socket.sent.contains { $0.contains("\"op.result\"") } }
        await waitUntil { indicator.hides >= 1 }
        #expect(indicator.hides >= 1)
        center.stop()
    }

    @Test("緊急停止は実行中操作を破棄して、許可の失効を部屋へ伝える")
    func emergencyStopCancelsAndRevokes() async {
        let socket = ScriptedSocket()
        let factory = ScriptedSocketFactory()
        let executor = ScriptedOperator()
        executor.handler = { op in
            // キャンセルされるまで待ち続ける。
            try await Task.sleep(for: .seconds(30))
            return .makeSuccess(["ok": true])
        }
        let center = await makeConnected(socket: socket, factory: factory, operator: executor)
        socket.feed(
            #"{"type":"op","op_id":"op-8","run_id":"run-1","job_id":"job-1","kind":"type_text","params":{"text":"あ"}}"#
        )
        await waitUntil { executor.received.count == 1 }
        center.emergencyStop()
        await waitUntil { socket.sent.contains { $0.contains("\"type\":\"state\"") } }
        #expect(stateEvents(socket.sent).last == "stop")
        // 実行中の操作は「キャンセルで失敗」として返る（成功扱いにしない）。
        await waitUntil { socket.sent.contains { $0.contains("\"op.result\"") } }
        let results = socket.sent.filter { $0.contains("\"op.result\"") }
        #expect(results.allSatisfy { $0.contains("\"ok\":false") && $0.contains("\"canceled\"") })
        center.stop()
    }

    @Test("終了時は state(quit) を best-effort で送る")
    func quitSendsState() async {
        let socket = ScriptedSocket()
        let factory = ScriptedSocketFactory()
        let center = await makeConnected(socket: socket, factory: factory)
        center.sendQuit()
        await waitUntil { socket.sent.contains { $0.contains("\"quit\"") } }
        #expect(socket.sent.last?.contains("\"quit\"") ?? false)
        center.stop()
    }
}
