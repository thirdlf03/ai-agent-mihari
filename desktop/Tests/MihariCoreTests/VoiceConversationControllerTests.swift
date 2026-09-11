import Foundation
import Testing

@testable import MihariCore

/// 会話コントローラの WS 受信・合成・割り込みを、差し替えで確かめる。
/// HTTP スタブは全テスト共有の静的状態なので、順次実行にして並び替えの干渉を防ぐ。
@Suite("voice 会話コントローラ", .serialized)
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
            lock.withLock {
                makeCount += 1
                if pending.isEmpty { return ScriptedSocket() }
                return pending.removeFirst()
            }
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
            JobSteerResponse(jobID: jobID, seq: 1, text: instruction, delivered: true)
        }
        func answerQuestion(jobID: String, questionID: String, answer: String) async throws -> JobQuestionAnswerResponse {
            JobQuestionAnswerResponse(
                jobID: jobID,
                question: RoomPendingQuestion(id: questionID, question: "?", status: "answered", answer: answer)
            )
        }
        func fetchJob(jobID: String) async throws -> RoomJobDetail {
            RoomJobDetail(jobID: jobID, status: "running")
        }
        func listRunning() async throws -> [RoomJobDetail] { [] }
    }

    private struct StubScreenCapture: VoiceScreenCapturing {
        /// サムネイル生成が通るよう、実際にデコードできる 1x1 PNG を返す。
        func captureMouseDisplayPNG() async throws -> VoiceScreenCaptureResult {
            VoiceScreenCaptureResult(pngData: Self.tinyPNG, displayTitle: "Main", displayID: 1)
        }

        private static let tinyPNG = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )!
    }

    private func makeController(
        socket: ScriptedSocket,
        player: SpeechPlayer = SpeechPlayer(),
        factory: ScriptedSocketFactory? = nil,
        micPermission: PermissionGrant = .granted
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
                onJobSubmitted: nil,
                checkMicPermission: { PermissionState(grant: micPermission, detail: "test") },
                requestMicPermission: { micPermission == .granted }
            )
        )
        return (controller, stubMic, socket, factory)
    }

    /// フレーム処理や送信の追いつきを待つ。固定の実時間待ちは並列で詰まると
    /// 間に合わないので、条件が揃うまで短い間隔で見る(上限は settle より長め)。
    private func waitUntil(_ condition: () -> Bool, attempts: Int = 1500) async {
        for _ in 0..<attempts {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
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
        let (controller, _, _, factory) = makeController(socket: socket)
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)
        socket.feed(
            """
            {"type":"history.sync","messages":[\
            {"role":"user","text":"以前の質問","ts":10.0,"kind":"text"},\
            {"role":"assistant","text":"以前の回答","ts":11.0,"kind":"text"}\
            ]}
            """
        )

        await waitUntil {
            controller.messages.contains(where: { $0.text == "以前の回答" })
        }

        #expect(controller.messages.map(\.role) == [.user, .assistant])
        #expect(controller.messages.map(\.text) == ["以前の質問", "以前の回答"])
        #expect(!controller.messages.contains(where: { $0.text == "会話を開始した" }))
        #expect(controller.statusText.contains("履歴を同期"))

        controller.stop()
    }

    @Test("capture_screen ツールで input.image を送る")
    func handlesCaptureScreenToolCall() async throws {
        let socket = ScriptedSocket()
        let (controller, _, _, factory) = makeController(socket: socket)
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)
        socket.feed(
            #"{"type":"assistant.tool_call","name":"capture_screen","call_id":"c1","arguments":"{\"prompt\":\"見て\"}"}"#
        )

        await waitUntil {
            socket.sent.contains { $0.contains("\"input.image\"") }
                && controller.messages.contains { $0.imageThumbnailPNG != nil }
        }

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
        let (controller, _, _, factory) = makeController(socket: socket)
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)
        socket.feed(#"{"type":"assistant.text","delta":"こんにちは","done":true}"#)

        await waitUntil { controller.connectionState == .ready }
        await waitUntil {
            controller.messages.contains(where: { $0.role == .assistant && $0.text == "こんにちは" })
        }

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
        let (controller, mic, _, factory) = makeController(socket: socket, player: player)
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        mic.emit(data: Data(repeating: 0, count: 480), level: 0.5)

        await waitUntil { player.isSpeaking == false }
        #expect(player.isSpeaking == false)

        controller.stop()
    }

    @Test("発話確定時はバッファ全体を再送せず commit だけ送る")
    func commitTurnDoesNotResendBufferedAudio() async throws {
        let socket = ScriptedSocket()
        let (controller, mic, _, factory) = makeController(socket: socket)
        controller.start()
        // ソケットが開く前に emit したチャンクは捨てられるため、接続を待ってから送る。
        await waitUntil { factory.makeCount >= 1 }
        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)

        let chunkA = Data(repeating: 0xAA, count: 480)
        let chunkB = Data(repeating: 0xBB, count: 480)
        mic.emit(data: chunkA, level: 0.5)
        mic.emit(data: chunkB, level: 0.5)
        mic.emit(data: Data(), level: 0.0)

        // 無音の見張りが発話を確定し、commit フレームが出るまで待つ。
        await waitUntil {
            self.parseSentAudioFrames(socket.sent).contains { ($0["commit"] as? Bool) == true }
        }

        let frames = parseSentAudioFrames(socket.sent)
        #expect(frames.count >= 3)

        let streaming = frames.filter { ($0["commit"] as? Bool) == false }
        let commits = frames.filter { ($0["commit"] as? Bool) == true }
        #expect(streaming.count == 2)
        let commitFrame = try #require(commits.first)
        #expect(commitFrame["create_response"] as? Bool == true)

        let commitAudio = commitFrame["audio_base64"] as? String ?? ""
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

        let (controller, _, first, _) = makeController(socket: firstSocket, factory: factory)
        // makeController がスタブを既定へ戻すため、並びの指定はそのあとに行う。
        VoiceSessionClientTestsURLProtocol.mode = .sequential
        VoiceSessionClientTestsURLProtocol.responses = [
            .create(sessionID: "sess-1"),
            .create(sessionID: "sess-2"),
        ]
        controller.start()
        await waitUntil { factory.makeCount >= 1 }
        first.feed(#"{"type":"session.ready","session_id":"sess-1","model":"mini"}"#)
        first.feed(#"{"type":"session.closed","reason":"done"}"#)
        first.finish()

        await waitUntil { factory.makeCount >= 2 }

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

        let (controller, _, first, _) = makeController(socket: firstSocket, factory: factory)
        // makeController がスタブを既定へ戻すため、並びの指定はそのあとに行う。
        VoiceSessionClientTestsURLProtocol.mode = .sequential
        VoiceSessionClientTestsURLProtocol.responses = [
            .create(sessionID: "sess-1"),
            .status("closed"),
            .create(sessionID: "sess-2"),
        ]
        controller.start()
        await waitUntil { factory.makeCount >= 1 }
        first.feed(#"{"type":"session.ready","session_id":"sess-1","model":"mini"}"#)
        first.finish()

        await waitUntil { factory.makeCount >= 2 }

        #expect(factory.makeCount == 2)
        #expect(controller.messages.contains(where: {
            $0.role == .system && $0.text.contains("新規セッション")
        }))

        controller.stop()
    }

    @Test("done の全文は delta の累積を置き換え、応答が二重にならない")
    func doneFullTextDoesNotDuplicateAssistantMessage() async throws {
        let socket = ScriptedSocket()
        let (controller, _, _, factory) = makeController(socket: socket)
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)
        socket.feed(#"{"type":"assistant.text","delta":"こんに","done":false}"#)
        socket.feed(#"{"type":"assistant.text","delta":"ちは","done":false}"#)
        socket.feed(#"{"type":"assistant.text","text":"こんにちは","done":true}"#)

        await waitUntil {
            controller.messages.contains(where: { $0.role == .assistant && $0.text == "こんにちは" })
        }

        let assistantTexts = controller.messages.filter { $0.role == .assistant }.map(\.text)
        #expect(assistantTexts == ["こんにちは"])

        controller.stop()
    }

    @Test("発話中はしきい値未満のチャンクも切り捨てずに送る")
    func sendsQuietChunksWhileUserIsSpeaking() async throws {
        let socket = ScriptedSocket()
        let (controller, mic, _, factory) = makeController(socket: socket)
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)

        let loud = Data(repeating: 0x11, count: 480)
        let quiet = Data(repeating: 0x22, count: 480)
        mic.emit(data: loud, level: 0.5)
        // 語尾の小さい音。発話中なのでしきい値未満でも送る。
        mic.emit(data: quiet, level: 0.005)

        await waitUntil {
            self.parseSentAudioFrames(socket.sent)
                .filter { ($0["commit"] as? Bool) == false }.count >= 2
        }

        let streaming = parseSentAudioFrames(socket.sent).filter { ($0["commit"] as? Bool) == false }
        let payloads = streaming.compactMap { $0["audio_base64"] as? String }
            .compactMap { Data(base64Encoded: $0) }
        #expect(payloads.contains(loud))
        #expect(payloads.contains(quiet))

        controller.stop()
    }

    @Test("user.text の文字起こしでプレースホルダが本当の文に置き換わる")
    func userTextReplacesPlaceholder() async throws {
        let socket = ScriptedSocket()
        let (controller, mic, _, factory) = makeController(socket: socket)
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)

        mic.emit(data: Data(repeating: 0x33, count: 480), level: 0.5)

        // 無音が続いて発話が確定し、プレースホルダが置かれるまで待つ。
        await waitUntil {
            controller.messages.last?.role == .user
                && controller.messages.last?.text == "（音声を送信）"
        }
        #expect(controller.messages.last?.role == .user)
        #expect(controller.messages.last?.text == "（音声を送信）")

        socket.feed(#"{"type":"user.text","text":"今日の予定を教えて"}"#)
        await waitUntil {
            controller.messages.last?.role == .user
                && controller.messages.last?.text == "今日の予定を教えて"
        }

        let userMessages = controller.messages.filter { $0.role == .user }
        #expect(userMessages.count == 1)
        #expect(userMessages.last?.text == "今日の予定を教えて")

        controller.stop()
    }

    @Test("マイク権限が無ければキャプチャを始めず理由を出す")
    func micPermissionDeniedDoesNotStartCapture() async throws {
        let socket = ScriptedSocket()
        let (controller, mic, _, _) = makeController(socket: socket, micPermission: .denied)
        controller.start()

        await waitUntil {
            controller.messages.contains(where: { $0.text.contains("マイクの利用許可") })
        }

        #expect(mic.started == false)
        #expect(controller.isMicLive == false)
        // statusText は接続処理に上書きされるため、履歴に残る文言を見る。
        #expect(controller.messages.contains(where: { $0.text.contains("マイクの利用許可") }))

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

/// VoiceConversationControllerTests 用の HTTP スタブ。VoiceScreenCaptureTests からも使う。
final class VoiceSessionClientTestsURLProtocol: URLProtocol, @unchecked Sendable {
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
