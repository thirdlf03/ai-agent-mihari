import Foundation
import Testing

@testable import MihariCore

/// 会話コントローラの WS 受信・合成・割り込みを、差し替えで確かめる。
@Suite("voice 会話コントローラ")
@MainActor
struct VoiceConversationControllerTests {

    private final class ScriptedSocket: VoiceStreamSocket, @unchecked Sendable {
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

    private final class ScriptedSocketFactory: VoiceStreamSocketFactory, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [ScriptedSocket] = []

        func queue(_ socket: ScriptedSocket) {
            lock.lock()
            pending.append(socket)
            lock.unlock()
        }

        func makeSocket(url: URL, token: String) async throws -> any VoiceStreamSocket {
            lock.lock()
            defer { lock.unlock() }
            if pending.isEmpty { return ScriptedSocket() }
            return pending.removeFirst()
        }
    }

    private final class StubMic: MicCapturing {
        var onChunk: (@Sendable (Data, Float) -> Void)?
        private(set) var started = false

        var isRunning: Bool { started }

        func start() throws { started = true }

        func stop() { started = false }

        func emit(data: Data, level: Float) {
            onChunk?(data, level)
        }
    }

    private func makeController(
        socket: ScriptedSocket,
        player: SpeechPlayer = SpeechPlayer()
    ) -> (VoiceConversationController, StubMic, ScriptedSocket) {
        let factory = ScriptedSocketFactory()
        factory.queue(socket)

        let stubMic = StubMic()
        let endpoint = VoiceSessionEndpoint(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            token: "token"
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceSessionClientTestsURLProtocol.self]
        VoiceSessionClientTestsURLProtocol.createResponse = VoiceSessionCreateResponse(
            sessionID: "sess-test",
            model: "gpt-realtime-2.1-mini",
            status: "created",
            protocolVersion: 1,
            streamPath: "/voice/sessions/sess-test/stream"
        )
        let session = URLSession(configuration: configuration)
        let client = VoiceSessionClient(endpoint: endpoint, session: session)

        let controller = VoiceConversationController(
            deps: VoiceConversationController.Dependencies(
                connector: VoiceStreamConnector(
                    client: client,
                    socketFactory: factory,
                    endpoint: endpoint
                ),
                speechPlayer: player,
                voicevox: VoicevoxClient(
                    configuration: VoicevoxConfiguration(
                        baseURL: URL(string: "http://127.0.0.1:50021")!,
                        speakerID: 14,
                        tuning: .standard,
                        queryTimeout: 1,
                        synthesisTimeout: 1
                    ),
                    session: session
                ),
                micFactory: { stubMic }
            )
        )
        return (controller, stubMic, socket)
    }

    @Test("session.ready で ready になり、assistant.text が履歴に載る")
    func handlesAssistantText() async throws {
        let socket = ScriptedSocket()
        let (controller, _, _) = makeController(socket: socket)
        controller.start()

        try await Task.sleep(for: .milliseconds(100))

        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)
        socket.feed(#"{"type":"assistant.text","delta":"こんにちは","done":true}"#)

        try await Task.sleep(for: .milliseconds(200))

        #expect(controller.connectionState == .ready)
        #expect(controller.messages.contains(where: { $0.role == .assistant && $0.text == "こんにちは" }))

        controller.stop()
    }

    @Test("再生中の割り込みで chatter 再生を止める")
    func bargeInStopsPlayback() async throws {
        let player = SpeechPlayer()
        let wav = try makeSilentWAV()
        #expect(player.play(audio: wav, priority: .chatter))

        let socket = ScriptedSocket()
        let (controller, mic, _) = makeController(socket: socket, player: player)
        controller.start()

        mic.emit(data: Data(repeating: 0, count: 480), level: 0.5)

        try await Task.sleep(for: .milliseconds(50))
        #expect(player.isSpeaking == false)

        controller.stop()
    }

    private func makeSilentWAV() throws -> Data {
        var data = Data("RIFF".utf8)
        data.append(contentsOf: [0x24, 0, 0, 0])
        data.append(contentsOf: "WAVEfmt ".utf8)
        data.append(contentsOf: [16, 0, 0, 0, 1, 0, 1, 0])
        data.append(contentsOf: [0x44, 0xAC, 0, 0, 0x88, 0x58, 0x01, 0])
        data.append(contentsOf: [2, 0, 16, 0])
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: [2, 0, 0, 0, 0, 0])
        return data
    }
}

/// VoiceConversationControllerTests 用の HTTP スタブ。
private final class VoiceSessionClientTestsURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var createResponse = VoiceSessionCreateResponse(
        sessionID: "sess-test",
        model: "gpt-realtime-2.1-mini",
        status: "created",
        protocolVersion: 1,
        streamPath: "/voice/sessions/sess-test/stream"
    )

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let data = Data(
            """
            {"session_id":"sess-test","model":"gpt-realtime-2.1-mini","status":"created",\
            "protocol_version":1,"stream_path":"/voice/sessions/sess-test/stream"}
            """.utf8
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
