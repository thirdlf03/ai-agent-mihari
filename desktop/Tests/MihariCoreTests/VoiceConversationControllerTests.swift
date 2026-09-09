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
        private(set) var makeCount = 0

        func queue(_ socket: ScriptedSocket) {
            lock.lock()
            pending.append(socket)
            lock.unlock()
        }

        func makeSocket(url: URL, token: String) async throws -> any VoiceStreamSocket {
            lock.lock()
            makeCount += 1
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

    private struct StubJobCollaboration: VoiceJobCollaborating {
        func submitJob(title: String, body: String) async throws -> JobRequestResponse {
            JobRequestResponse(jobID: "job-test", status: "queued")
        }
        func steer(jobID: String, instruction: String) async throws -> JobSteerResponse {
            JobSteerResponse(jobID: jobID, status: "running")
        }
        func answerQuestion(jobID: String, questionID: String, answer: String) async throws -> JobQuestionAnswerResponse {
            JobQuestionAnswerResponse(jobID: jobID, questionID: questionID, status: "running")
        }
        func fetchJob(jobID: String) async throws -> RoomJobDetail {
            RoomJobDetail(jobID: jobID, status: "running")
        }
        func listRunning() async throws -> [RoomJobDetail] { [] }
    }

    private struct StubScreenCapture: VoiceScreenCapturing {
        func captureMouseDisplayPNG() async throws -> VoiceScreenCaptureResult {
            VoiceScreenCaptureResult(pngData: Data([0x89, 0x50, 0x4E, 0x47]), displayTitle: "Main", displayID: 1)
        }
    }

    private func makeController(
        socket: ScriptedSocket,
        player: SpeechPlayer = SpeechPlayer(),
        factory: ScriptedSocketFactory? = nil
    ) -> (VoiceConversationController, StubMic, ScriptedSocket, ScriptedSocketFactory) {
        let factory = factory ?? ScriptedSocketFactory()
        factory.queue(socket)

        let stubMic = StubMic()
        let endpoint = VoiceSessionEndpoint(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            token: "token"
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceSessionClientTestsURLProtocol.self]
        VoiceSessionClientTestsURLProtocol.mode = .fixed
        VoiceSessionClientTestsURLProtocol.responses = []
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
                micFactory: { stubMic },
                jobCollaboration: StubJobCollaboration(),
                screenCapture: StubScreenCapture(),
                onJobSubmitted: nil
            )
        )
        return (controller, stubMic, socket, factory)
    }

    private func parseSentAudioFrames(_ sent: [String]) -> [[String: Any]] {
        sent.compactMap { text in
            guard
                let data = text.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                json["type"] as? String == "input.audio"
            else {
                return nil
            }
            return json
        }
    }

    @Test("history.sync でローカル履歴を room の内容に置き換える")
    func historySyncReplacesLocalMessages() async throws {
        let socket = ScriptedSocket()
        let (controller, _, _, _) = makeController(socket: socket)
        controller.start()

        try await Task.sleep(for: .milliseconds(100))
        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)
        socket.feed(
            """
            {"type":"history.sync","messages":[\
            {"role":"user","text":"以前の質問","ts":10.0,"kind":"text"},\
            {"role":"assistant","text":"以前の回答","ts":11.0,"kind":"text"}\
            ]}
            """
        )

        try await Task.sleep(for: .milliseconds(100))

        #expect(controller.messages.count == 2)
        #expect(controller.messages[0].role == .user)
        #expect(controller.messages[0].text == "以前の質問")
        #expect(controller.messages[1].role == .assistant)
        #expect(controller.messages[1].text == "以前の回答")
        #expect(!controller.messages.contains(where: { $0.text == "会話を開始した" }))
        #expect(controller.statusText.contains("履歴を同期"))

        controller.stop()
    }

    @Test("capture_screen ツールで input.image を送る")
    func handlesCaptureScreenToolCall() async throws {
        let socket = ScriptedSocket()
        let (controller, _, _, _) = makeController(socket: socket)
        controller.start()

        try await Task.sleep(for: .milliseconds(100))
        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)
        socket.feed(
            #"{"type":"assistant.tool_call","name":"capture_screen","call_id":"c1","arguments":"{\"prompt\":\"見て\"}"}"#
        )

        try await Task.sleep(for: .milliseconds(200))

        let sentImage = socket.sent.contains { text in
            guard
                let data = text.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return json["type"] as? String == "input.image"
        }
        #expect(sentImage)
        #expect(controller.messages.contains(where: { $0.imageThumbnailPNG != nil }))

        controller.stop()
    }

    @Test("session.ready で ready になり、assistant.text が履歴に載る")
    func handlesAssistantText() async throws {
        let socket = ScriptedSocket()
        let (controller, _, _, _) = makeController(socket: socket)
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
        let (controller, mic, _, _) = makeController(socket: socket, player: player)
        controller.start()

        mic.emit(data: Data(repeating: 0, count: 480), level: 0.5)

        try await Task.sleep(for: .milliseconds(50))
        #expect(player.isSpeaking == false)

        controller.stop()
    }

    @Test("発話確定時はバッファ全体を再送せず commit だけ送る")
    func commitTurnDoesNotResendBufferedAudio() async throws {
        let socket = ScriptedSocket()
        let (controller, mic, _, _) = makeController(socket: socket)
        controller.start()

        try await Task.sleep(for: .milliseconds(100))
        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)

        let chunkA = Data(repeating: 0xAA, count: 480)
        let chunkB = Data(repeating: 0xBB, count: 480)
        mic.emit(data: chunkA, level: 0.5)
        mic.emit(data: chunkB, level: 0.5)
        mic.emit(data: Data(), level: 0.0)

        try await Task.sleep(for: .milliseconds(850))

        let frames = parseSentAudioFrames(socket.sent)
        #expect(frames.count >= 3)

        let streaming = frames.filter { ($0["commit"] as? Bool) == false }
        let commits = frames.filter { ($0["commit"] as? Bool) == true }
        #expect(streaming.count == 2)
        #expect(commits.count == 1)
        #expect(commits[0]["create_response"] as? Bool == true)

        let commitAudio = commits[0]["audio_base64"] as? String ?? ""
        let commitBytes = Data(base64Encoded: commitAudio) ?? Data()
        #expect(commitBytes.count == 2)
        #expect(commitBytes != chunkA)
        #expect(commitBytes != chunkB)
        #expect(commitBytes != chunkA + chunkB)

        controller.stop()
    }

    @Test("session.closed 後の自動再接続は同一 ID に張り直さず新規セッションを作る")
    func autoReconnectUsesNewSessionAfterClosed() async throws {
        let firstSocket = ScriptedSocket()
        let secondSocket = ScriptedSocket()
        let factory = ScriptedSocketFactory()
        factory.queue(firstSocket)
        factory.queue(secondSocket)

        VoiceSessionClientTestsURLProtocol.mode = .sequential
        VoiceSessionClientTestsURLProtocol.responses = [
            .create(sessionID: "sess-1"),
            .create(sessionID: "sess-2"),
        ]

        let (controller, _, first, _) = makeController(socket: firstSocket, factory: factory)
        controller.start()

        try await Task.sleep(for: .milliseconds(100))
        first.feed(#"{"type":"session.ready","session_id":"sess-1","model":"mini"}"#)
        first.feed(#"{"type":"session.closed","reason":"done"}"#)
        first.finish()

        try await Task.sleep(for: .milliseconds(1200))

        #expect(factory.makeCount == 2)

        controller.stop()
    }

    @Test("切断後 GET が closed なら tryReconnect を諦めて新規セッションを作る")
    func reconnectFallbackWhenGetReturnsClosed() async throws {
        let firstSocket = ScriptedSocket()
        let secondSocket = ScriptedSocket()
        let factory = ScriptedSocketFactory()
        factory.queue(firstSocket)
        factory.queue(secondSocket)

        VoiceSessionClientTestsURLProtocol.mode = .sequential
        VoiceSessionClientTestsURLProtocol.responses = [
            .create(sessionID: "sess-1"),
            .status("closed"),
            .create(sessionID: "sess-2"),
        ]

        let (controller, _, first, _) = makeController(socket: firstSocket, factory: factory)
        controller.start()

        try await Task.sleep(for: .milliseconds(100))
        first.feed(#"{"type":"session.ready","session_id":"sess-1","model":"mini"}"#)
        first.finish()

        try await Task.sleep(for: .milliseconds(1200))

        #expect(factory.makeCount == 2)
        #expect(controller.messages.contains(where: {
            $0.role == .system && $0.text.contains("新規セッション")
        }))

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
    enum ResponseKind {
        case create(sessionID: String)
        case status(String)
    }

    nonisolated(unsafe) static var mode: Mode = .fixed
    nonisolated(unsafe) static var responses: [ResponseKind] = []
    nonisolated(unsafe) static var createResponse = VoiceSessionCreateResponse(
        sessionID: "sess-test",
        model: "gpt-realtime-2.1-mini",
        status: "created",
        protocolVersion: 1,
        streamPath: "/voice/sessions/sess-test/stream"
    )

    enum Mode {
        case fixed
        case sequential
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let data: Data
        if Self.mode == .sequential, !Self.responses.isEmpty {
            let kind = Self.responses.removeFirst()
            data = Self.body(for: kind)
        } else {
            data = Self.body(for: .create(sessionID: Self.createResponse.sessionID))
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(for kind: ResponseKind) -> Data {
        switch kind {
        case .create(let sessionID):
            return Data(
                """
                {"session_id":"\(sessionID)","model":"gpt-realtime-2.1-mini","status":"created",\
                "protocol_version":1,"stream_path":"/voice/sessions/\(sessionID)/stream"}
                """.utf8
            )
        case .status(let status):
            return Data(
                """
                {"session_id":"sess-1","model":"gpt-realtime-2.1-mini","status":"\(status)","error":null}
                """.utf8
            )
        }
    }
}
