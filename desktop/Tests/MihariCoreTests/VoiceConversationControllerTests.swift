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

    private final class TrackingJobCollaboration: VoiceJobCollaborating, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var steerCalls: [(jobID: String, instruction: String)] = []
        private(set) var answerCalls: [(jobID: String, questionID: String, answer: String)] = []

        func submitJob(title: String, body: String) async throws -> JobRequestResponse {
            JobRequestResponse(jobID: "job-active", status: "queued")
        }

        func steer(jobID: String, instruction: String) async throws -> JobSteerResponse {
            lock.withLock { steerCalls.append((jobID, instruction)) }
            return JobSteerResponse(jobID: jobID, seq: 1, text: instruction, delivered: true)
        }

        func answerQuestion(
            jobID: String,
            questionID: String,
            answer: String
        ) async throws -> JobQuestionAnswerResponse {
            lock.withLock { answerCalls.append((jobID, questionID, answer)) }
            return JobQuestionAnswerResponse(
                jobID: jobID,
                question: RoomPendingQuestion(id: questionID, question: "?", status: "answered", answer: answer)
            )
        }

        func fetchJob(jobID: String) async throws -> RoomJobDetail {
            RoomJobDetail(jobID: jobID, status: "running", pendingQuestions: [])
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
        jobCollaboration: (any VoiceJobCollaborating)? = nil,
        pcmPlayer: (any PCMStreamPlaying)? = nil,
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
        VoiceSessionClientTestsURLProtocol.resetRequests()
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
                jobCollaboration: jobCollaboration ?? StubJobCollaboration(),
                screenCapture: StubScreenCapture(),
                // 既定の実プレイヤーは AVAudioEngine を触るため、テストではスタブにする。
                pcmPlayer: pcmPlayer ?? VoiceConversationControllerTestsStubPCMPlayer(),
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

    @Test("assistant.audio は PCM プレーヤーへ流れ、assistant.text では VOICEVOX を呼ばない")
    func assistantAudioRoutesToPCMPlayerAndSkipsVoicevox() async throws {
        let socket = ScriptedSocket()
        let pcm = VoiceConversationControllerTestsStubPCMPlayer()
        let (controller, _, _, factory) = makeController(socket: socket, pcmPlayer: pcm)
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)

        let chunk = Data([0x01, 0x00, 0x02, 0x00])
        socket.feed(
            """
            {"type":"assistant.audio","audio_base64":"\(chunk.base64EncodedString())","done":false}
            """
        )
        socket.feed(#"{"type":"assistant.audio","audio_base64":"","done":true}"#)

        await waitUntil { pcm.finishCount >= 1 }
        #expect(pcm.chunks == [chunk])
        #expect(pcm.finishCount == 1)

        // テキストは履歴に載るが、audio モードなので合成は呼ばれない。
        socket.feed(#"{"type":"assistant.text","text":"ひまりの声で返す","done":true}"#)
        await waitUntil {
            controller.messages.contains(where: {
                $0.role == .assistant && $0.text == "ひまりの声で返す"
            })
        }
        // 合成を呼んでいたら届くはずの失敗メッセージが無いことも確認する。
        try await Task.sleep(for: .milliseconds(200))

        #expect(
            !VoiceSessionClientTestsURLProtocol.requests.contains {
                $0.path.contains("audio_query")
            }
        )
        #expect(!controller.messages.contains { $0.text.contains("VOICEVOX") })

        controller.stop()
    }

    @Test("assistant.audio が無いセッションは従来通り VOICEVOX 合成を呼ぶ")
    func assistantTextWithoutAudioModeCallsVoicevox() async throws {
        let socket = ScriptedSocket()
        let pcm = VoiceConversationControllerTestsStubPCMPlayer()
        let (controller, _, _, factory) = makeController(socket: socket, pcmPlayer: pcm)
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)
        socket.feed(#"{"type":"assistant.text","text":"合成してね","done":true}"#)

        await waitUntil {
            VoiceSessionClientTestsURLProtocol.requests.contains { $0.path.contains("audio_query") }
        }

        #expect(
            VoiceSessionClientTestsURLProtocol.requests.contains {
                $0.path.contains("audio_query")
            }
        )
        #expect(pcm.chunks.isEmpty)

        controller.stop()
    }

    @Test("assistant.audio の再生中に「話す」を押すと PCM 再生を止める")
    func bargeInStopsPCMPlayback() async throws {
        let socket = ScriptedSocket()
        let pcm = VoiceConversationControllerTestsStubPCMPlayer()
        let (controller, _, _, factory) = makeController(socket: socket, pcmPlayer: pcm)
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)
        let chunk = Data([0x01, 0x00])
        socket.feed(
            """
            {"type":"assistant.audio","audio_base64":"\(chunk.base64EncodedString())","done":false}
            """
        )
        await waitUntil { controller.statusText == "再生中…" }

        controller.beginPushToTalk()

        await waitUntil { pcm.stopCount >= 1 }
        #expect(pcm.stopCount >= 1)

        controller.stop()
    }

    @Test("assistant.audio を鳴らし切ると待機状態へ戻る")
    func drainedReturnsToPrompt() async throws {
        let socket = ScriptedSocket()
        let pcm = VoiceConversationControllerTestsStubPCMPlayer()
        let (controller, _, _, factory) = makeController(socket: socket, pcmPlayer: pcm)
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)
        await waitUntil { controller.connectionState == .ready }

        let chunk = Data([0x01, 0x00])
        socket.feed(
            """
            {"type":"assistant.audio","audio_base64":"\(chunk.base64EncodedString())","done":false}
            """
        )
        await waitUntil { controller.statusText == "再生中…" }

        socket.feed(#"{"type":"assistant.audio","audio_base64":"","done":true}"#)
        await waitUntil { pcm.finishCount >= 1 }

        // 実機では最後のバッファの再生完了で呼ばれる。
        pcm.fireDrained()
        await waitUntil { controller.statusText == "話しかけてください" }

        #expect(controller.statusText == "話しかけてください")

        controller.stop()
    }

    @Test("会話終了で PCM プレーヤーを止める")
    func stopStopsPCMPlayer() async throws {
        let socket = ScriptedSocket()
        let pcm = VoiceConversationControllerTestsStubPCMPlayer()
        let (controller, _, _, factory) = makeController(socket: socket, pcmPlayer: pcm)
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)
        await waitUntil { controller.connectionState == .ready }

        controller.stop()

        #expect(pcm.stopCount >= 1)
    }

    @Test("再生中に「話す」を押すと割り込みで chatter 再生を止める")
    func bargeInStopsPlayback() async throws {
        let player = SpeechPlayer()
        let wav = try makeSilentWAV()
        #expect(player.play(audio: wav, priority: .chatter))

        let socket = ScriptedSocket()
        let (controller, _, _, factory) = makeController(socket: socket, player: player)
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        controller.beginPushToTalk()

        await waitUntil { player.isSpeaking == false }
        #expect(player.isSpeaking == false)

        controller.stop()
    }

    @Test("「話す」解放時はバッファ全体を再送せず commit だけ送る")
    func commitTurnDoesNotResendBufferedAudio() async throws {
        let socket = ScriptedSocket()
        let (controller, mic, _, factory) = makeController(socket: socket)
        controller.start()
        // ソケットが開く前に emit したチャンクは捨てられるため、接続を待ってから送る。
        await waitUntil { factory.makeCount >= 1 }
        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)

        let chunkA = Data(repeating: 0xAA, count: 480)
        let chunkB = Data(repeating: 0xBB, count: 480)
        controller.beginPushToTalk()
        mic.emit(data: chunkA, level: 0.5)
        mic.emit(data: chunkB, level: 0.5)

        // チャンク処理は MainActor 経由の非同期なので、2 つ送れたのを見てから離す。
        await waitUntil {
            self.parseSentAudioFrames(socket.sent)
                .filter { ($0["commit"] as? Bool) == false }.count >= 2
        }
        controller.endPushToTalk()

        // 解放で発話が確定し、commit フレームが出るまで待つ。
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

    @Test("steer_job ツールで room へ指示を送る")
    func handlesSteerJobToolCall() async throws {
        let socket = ScriptedSocket()
        let jobs = TrackingJobCollaboration()
        let (controller, _, _, _) = makeController(socket: socket, jobCollaboration: jobs)
        controller.start()

        try await Task.sleep(for: .milliseconds(100))
        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)
        socket.feed(
            #"{"type":"assistant.tool_call","name":"submit_job","call_id":"c0","arguments":"{\"body\":\"調査して\"}"}"#
        )
        try await Task.sleep(for: .milliseconds(200))
        socket.feed(
            #"{"type":"assistant.tool_call","name":"steer_job","call_id":"c1","arguments":"{\"instruction\":\"左側を優先\"}"}"#
        )
        try await Task.sleep(for: .milliseconds(200))

        #expect(jobs.steerCalls.count == 1)
        #expect(jobs.steerCalls[0].jobID == "job-active")
        #expect(jobs.steerCalls[0].instruction == "左側を優先")
        #expect(controller.messages.contains(where: {
            $0.role == .system && $0.text.contains("指示を送った")
        }))

        controller.stop()
    }

    @Test("show_job_question で pendingQuestions に載せ、回答を room へ送る")
    func handlesPendingQuestionFlow() async throws {
        let socket = ScriptedSocket()
        let jobs = TrackingJobCollaboration()
        let (controller, _, _, _) = makeController(socket: socket, jobCollaboration: jobs)
        controller.start()

        try await Task.sleep(for: .milliseconds(100))
        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)
        socket.feed(
            #"{"type":"assistant.tool_call","name":"show_job_question","call_id":"c2","arguments":"{\"job_id\":\"j1\",\"question_id\":\"q1\",\"prompt\":\"続けますか？\"}"}"#
        )
        try await Task.sleep(for: .milliseconds(200))

        #expect(controller.pendingQuestions.count == 1)
        #expect(controller.pendingQuestions[0].questionID == "q1")
        #expect(controller.pendingQuestions[0].prompt == "続けますか？")

        controller.submitPendingQuestionAnswer("はい", questionID: "q1")
        try await Task.sleep(for: .milliseconds(200))

        #expect(jobs.answerCalls.count == 1)
        #expect(jobs.answerCalls[0].answer == "はい")
        #expect(controller.pendingQuestions.isEmpty)

        controller.stop()
    }

    @Test("error フレームは system メッセージになる")
    func handlesErrorFrame() async throws {
        let socket = ScriptedSocket()
        let (controller, _, _, _) = makeController(socket: socket)
        controller.start()

        try await Task.sleep(for: .milliseconds(100))
        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)
        socket.feed(
            #"{"type":"error","code":"upstream_error","message":"Realtime が落ちた"}"#
        )
        try await Task.sleep(for: .milliseconds(200))

        #expect(controller.messages.contains(where: {
            $0.role == .system && $0.text.contains("エラー: Realtime が落ちた")
        }))

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

    @Test("「話す」押下中は音量に関係なくすべてのチャンクを送る")
    func sendsAllChunksWhileTalking() async throws {
        let socket = ScriptedSocket()
        let (controller, mic, _, factory) = makeController(socket: socket)
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)

        let loud = Data(repeating: 0x11, count: 480)
        let quiet = Data(repeating: 0x22, count: 480)
        controller.beginPushToTalk()
        mic.emit(data: loud, level: 0.5)
        // 語尾の小さい音。押下中なのでレベルに関係なく送る。
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

    @Test("「話す」を押していない間は音声チャンクを送らない")
    func dropsMicChunksUnlessTalking() async throws {
        let socket = ScriptedSocket()
        let (controller, mic, _, factory) = makeController(socket: socket)
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)

        mic.emit(data: Data(repeating: 0x44, count: 480), level: 0.5)

        // 送信は非同期なので、流れていれば届く程度の時間だけ待ってから確認する。
        try await Task.sleep(for: .milliseconds(200))
        #expect(parseSentAudioFrames(socket.sent).isEmpty)
        #expect(controller.isMicLive == false)

        controller.stop()
    }

    @Test("押してすぐ離し音声が無ければ確定もプレースホルダも送らない")
    func releaseWithoutAudioDoesNotCommit() async throws {
        let socket = ScriptedSocket()
        let (controller, _, _, factory) = makeController(socket: socket)
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)

        controller.beginPushToTalk()
        controller.endPushToTalk()

        try await Task.sleep(for: .milliseconds(200))
        #expect(parseSentAudioFrames(socket.sent).isEmpty)
        #expect(!controller.messages.contains(where: { $0.text == "（音声を送信）" }))

        controller.stop()
    }

    @Test("user.text の文字起こしでプレースホルダが本当の文に置き換わる")
    func userTextReplacesPlaceholder() async throws {
        let socket = ScriptedSocket()
        let (controller, mic, _, factory) = makeController(socket: socket)
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)

        controller.beginPushToTalk()
        mic.emit(data: Data(repeating: 0x33, count: 480), level: 0.5)

        // チャンク処理は MainActor 経由の非同期なので、送れたのを見てから離す。
        await waitUntil {
            !self.parseSentAudioFrames(socket.sent).isEmpty
        }
        controller.endPushToTalk()

        // 解放で発話が確定し、プレースホルダが置かれるまで待つ。
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

    @Test("live_audio の逐次 user.text は行を増やさず累積 text で書き換える")
    func streamingUserTextRewritesSingleLine() async throws {
        let socket = ScriptedSocket()
        let (controller, _, _, factory) = makeController(socket: socket)
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)
        socket.feed(#"{"type":"user.text","text":"こ","delta":"こ","done":false}"#)
        socket.feed(#"{"type":"user.text","text":"こんに","delta":"んに","done":false}"#)
        socket.feed(#"{"type":"user.text","text":"こんにちは","delta":"ちは","done":false}"#)

        await waitUntil {
            controller.messages.contains(where: { $0.role == .user && $0.text == "こんにちは" })
        }

        // 断片ごとに行が増えず、累積全文で末尾の user 行が書き換わるだけ。
        let userMessages = controller.messages.filter { $0.role == .user }
        #expect(userMessages.count == 1)
        #expect(userMessages.last?.text == "こんにちは")

        controller.stop()
    }

    @Test("逐次 user.text の done で確定し、次の発話は新しい行から始まる")
    func streamingUserTextDoneStartsNewLineForNextUtterance() async throws {
        let socket = ScriptedSocket()
        let (controller, _, _, factory) = makeController(socket: socket)
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)
        socket.feed(#"{"type":"user.text","text":"一つ目","delta":"一つ目","done":false}"#)
        socket.feed(#"{"type":"user.text","text":"一つ目の発話","done":true}"#)
        socket.feed(#"{"type":"user.text","text":"二","delta":"二","done":false}"#)
        socket.feed(#"{"type":"user.text","text":"二つ目の発話","done":true}"#)

        await waitUntil {
            controller.messages.filter { $0.role == .user }.count == 2
                && controller.messages.last?.text == "二つ目の発話"
        }

        // 2 回の発話が混ざらず、それぞれ確定文の 1 行ずつになる。
        let userTexts = controller.messages.filter { $0.role == .user }.map(\.text)
        #expect(userTexts == ["一つ目の発話", "二つ目の発話"])

        controller.stop()
    }

    @Test("従来形式の user.text（delta/done 無し）は従来通り新規行を追加する")
    func legacyUserTextStillAppendsNewLines() async throws {
        let socket = ScriptedSocket()
        let (controller, _, _, factory) = makeController(socket: socket)
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)
        socket.feed(#"{"type":"user.text","text":"最初の発話"}"#)
        socket.feed(#"{"type":"user.text","text":"次の発話"}"#)

        await waitUntil {
            controller.messages.filter { $0.role == .user }.count == 2
        }

        let userTexts = controller.messages.filter { $0.role == .user }.map(\.text)
        #expect(userTexts == ["最初の発話", "次の発話"])

        controller.stop()
    }

    @Test("逐次 user.text はプッシュ・トゥ・トークのプレースホルダ行を書き換える")
    func streamingUserTextReplacesPlaceholder() async throws {
        let socket = ScriptedSocket()
        let (controller, mic, _, factory) = makeController(socket: socket)
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)

        controller.beginPushToTalk()
        mic.emit(data: Data(repeating: 0x55, count: 480), level: 0.5)
        await waitUntil {
            !self.parseSentAudioFrames(socket.sent).isEmpty
        }
        controller.endPushToTalk()

        await waitUntil {
            controller.messages.last?.role == .user
                && controller.messages.last?.text == "（音声を送信）"
        }

        socket.feed(#"{"type":"user.text","text":"画面を","delta":"画面を","done":false}"#)
        socket.feed(#"{"type":"user.text","text":"画面を見て","done":true}"#)

        await waitUntil {
            controller.messages.last?.role == .user
                && controller.messages.last?.text == "画面を見て"
        }

        let userMessages = controller.messages.filter { $0.role == .user }
        #expect(userMessages.count == 1)
        #expect(userMessages.last?.text == "画面を見て")

        controller.stop()
    }

    @Test("会話終了で room へセッション close を送る")
    func stopClosesServerSession() async throws {
        let socket = ScriptedSocket()
        let (controller, _, _, factory) = makeController(socket: socket)
        // 前テストの非同期 close と区別するため固有のセッション ID を使う。
        VoiceSessionClientTestsURLProtocol.mode = .sequential
        VoiceSessionClientTestsURLProtocol.responses = [.create(sessionID: "sess-stop")]
        controller.start()
        await waitUntil { factory.makeCount >= 1 }

        socket.feed(#"{"type":"session.ready","session_id":"sess-stop","model":"mini"}"#)
        await waitUntil { controller.connectionState == .ready }

        controller.stop()

        await waitUntil {
            VoiceSessionClientTestsURLProtocol.requests.contains {
                $0.method == "POST" && $0.path == "/voice/sessions/sess-stop/close"
            }
        }

        #expect(
            VoiceSessionClientTestsURLProtocol.requests.contains {
                $0.method == "POST" && $0.path == "/voice/sessions/sess-stop/close"
            }
        )
    }

    @Test("再接続では旧セッションを close してから新規作成する")
    func reconnectClosesSessionBeforeCreatingNew() async throws {
        let firstSocket = ScriptedSocket()
        let secondSocket = ScriptedSocket()
        let factory = ScriptedSocketFactory()
        factory.queue(firstSocket)
        factory.queue(secondSocket)

        let (controller, _, first, _) = makeController(socket: firstSocket, factory: factory)
        // 前テストの非同期 close と区別するため固有のセッション ID を使う。
        VoiceSessionClientTestsURLProtocol.mode = .sequential
        VoiceSessionClientTestsURLProtocol.responses = [
            .create(sessionID: "sess-r1"),
            .create(sessionID: "sess-r2"),
        ]
        controller.start()
        await waitUntil { factory.makeCount >= 1 }
        first.feed(#"{"type":"session.ready","session_id":"sess-r1","model":"mini"}"#)
        await waitUntil { controller.connectionState == .ready }

        controller.reconnect()
        await waitUntil { factory.makeCount >= 2 }

        let requests = VoiceSessionClientTestsURLProtocol.requests
        let creates = requests.enumerated().compactMap { index, request in
            request.method == "POST" && request.path == "/voice/sessions" ? index : nil
        }
        let closeIndex = requests.firstIndex {
            $0.method == "POST" && $0.path == "/voice/sessions/sess-r1/close"
        }
        #expect(creates.count >= 2)
        let closeAt = try #require(closeIndex)
        #expect(closeAt > creates[0])
        #expect(closeAt < creates[1])

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

/// `assistant.audio` の再生口のスタブ。実プレイヤーは AVAudioEngine を触るため、
/// テストではこれで呼び出しを記録する。VoiceScreenCaptureTests からも使う。
final class VoiceConversationControllerTestsStubPCMPlayer: PCMStreamPlaying, @unchecked Sendable {
    private let lock = NSLock()
    private var _startCount = 0
    private var _stopCount = 0
    private var _finishCount = 0
    private var _chunks: [Data] = []

    var onDrained: (@Sendable () -> Void)?

    var startCount: Int { lock.withLock { _startCount } }
    var stopCount: Int { lock.withLock { _stopCount } }
    var finishCount: Int { lock.withLock { _finishCount } }
    var chunks: [Data] { lock.withLock { _chunks } }

    func start() {
        lock.withLock { _startCount += 1 }
    }

    func enqueue(pcm16: Data) {
        lock.withLock { _chunks.append(pcm16) }
    }

    func finish() {
        lock.withLock { _finishCount += 1 }
    }

    func stop() {
        lock.withLock { _stopCount += 1 }
    }

    /// 実機では最後のバッファの再生完了で呼ばれる `onDrained` を手で発火させる。
    func fireDrained() {
        onDrained?()
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
    /// 受けた HTTP リクエストの履歴（method, path）。close 順序の検証用。
    nonisolated(unsafe) private static var _requests: [(method: String, path: String)] = []
    private static let requestsLock = NSLock()

    static var requests: [(method: String, path: String)] {
        requestsLock.withLock { _requests }
    }

    static func resetRequests() {
        requestsLock.withLock { _requests = [] }
    }
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
        Self.requestsLock.withLock {
            Self._requests.append((request.httpMethod ?? "", request.url?.path ?? ""))
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let data: Data
        // close は sequential の列を消費しない。前テストの非同期 close が
        // 後続テストへ流れ込んでもレスポンス並びをずらさないため。
        if request.url?.path.hasSuffix("/close") == true {
            data = Data(#"{"session_id":"x","status":"closed"}"#.utf8)
        } else if Self.mode == .sequential, !Self.responses.isEmpty {
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
