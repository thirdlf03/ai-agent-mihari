import CoreGraphics
import Foundation
import Testing

@testable import MihariCore

@Suite("voice 画面キャプチャ")
struct VoiceScreenCaptureTests {

    @Test("マウス位置を含むディスプレイを選ぶ")
    func selectsDisplayContainingPoint() {
        let displays = [
            MouseDisplayBounds(displayID: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), title: "左"),
            MouseDisplayBounds(displayID: 2, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080), title: "右"),
        ]
        #expect(MouseDisplaySelector.displayID(at: CGPoint(x: 100, y: 100), displays: displays) == 1)
        #expect(MouseDisplaySelector.displayID(at: CGPoint(x: 2000, y: 500), displays: displays) == 2)
    }

    @Test("どのディスプレイにも無い点は先頭に落とす")
    func fallsBackToFirstDisplay() {
        let displays = [
            MouseDisplayBounds(displayID: 10, bounds: CGRect(x: 0, y: 0, width: 800, height: 600), title: "Main"),
        ]
        #expect(MouseDisplaySelector.displayID(at: CGPoint(x: -50, y: -50), displays: displays) == 10)
    }

    @Test("input.image フレームを契約どおり組み立てる")
    func buildsInputImageFrame() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let text = try VoiceOutgoingFrame.inputImage(png: png, prompt: "画面を見て")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(json["type"] as? String == "input.image")
        #expect(json["image_base64"] as? String == png.base64EncodedString())
        #expect(json["media_type"] as? String == "image/png")
        #expect(json["prompt"] as? String == "画面を見て")
        #expect(json["create_response"] as? Bool == true)
    }

    @Test("スタブでマウスディスプレイを撮って送る")
    func captureAndSendUsesMouseDisplay() async throws {
        let png = Data("PNG".utf8)
        let socket = VoiceConversationCaptureTestsScriptedSocket()
        let controller = VoiceConversationCaptureTests.makeController(
            socket: socket,
            screenCapture: StubVoiceScreenCapture(
                result: VoiceScreenCaptureResult(pngData: png, displayTitle: "右", displayID: 2)
            )
        )
        controller.start()
        try await Task.sleep(for: .milliseconds(100))
        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)
        controller.captureAndSendScreen(prompt: "見て")
        try await Task.sleep(for: .milliseconds(200))

        let imageFrames = socket.sent.compactMap { text -> [String: Any]? in
            guard
                let data = text.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                json["type"] as? String == "input.image"
            else { return nil }
            return json
        }
        #expect(imageFrames.count == 1)
        #expect(imageFrames[0]["prompt"] as? String == "見て")
        #expect(controller.messages.contains(where: { $0.imageThumbnailPNG != nil }))
        controller.stop()
    }
}

/// capture テスト用のソケット。
private final class VoiceConversationCaptureTestsScriptedSocket: VoiceStreamSocket, @unchecked Sendable {
    private let stream: AsyncStream<String>
    private var iterator: AsyncStream<String>.Iterator
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var _sent: [String] = []

    init() {
        var continuation: AsyncStream<String>.Continuation!
        let stream = AsyncStream { continuation = $0 }
        self.stream = stream
        self.iterator = stream.makeAsyncIterator()
        self.continuation = continuation
    }

    func feed(_ text: String) { continuation.yield(text) }

    func send(_ text: String) async throws {
        lock.withLock { _sent.append(text) }
    }

    func receive() async throws -> String? {
        await iterator.next()
    }

    func close() async {
        continuation.finish()
    }

    var sent: [String] {
        lock.withLock { _sent }
    }
}

private struct StubVoiceScreenCapture: VoiceScreenCapturing {
    let result: VoiceScreenCaptureResult

    func captureMouseDisplayPNG() async throws -> VoiceScreenCaptureResult {
        result
    }
}

@MainActor
private enum VoiceConversationCaptureTests {
    static func makeController(
        socket: VoiceConversationCaptureTestsScriptedSocket,
        screenCapture: any VoiceScreenCapturing
    ) -> VoiceConversationController {
        let factory = VoiceConversationControllerTestsScriptedSocketFactory()
        factory.queue(socket)
        let endpoint = VoiceSessionEndpoint(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            token: "token"
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceSessionClientTestsURLProtocol.self]
        VoiceSessionClientTestsURLProtocol.mode = .fixed
        VoiceSessionClientTestsURLProtocol.responses = []
        let session = URLSession(configuration: configuration)
        let client = VoiceSessionClient(endpoint: endpoint, session: session)
        return VoiceConversationController(
            deps: VoiceConversationController.Dependencies(
                connector: VoiceStreamConnector(
                    client: client,
                    socketFactory: factory,
                    endpoint: endpoint
                ),
                speechPlayer: SpeechPlayer(),
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
                micFactory: { VoiceConversationControllerTestsStubMic() },
                jobCollaboration: VoiceConversationControllerTestsStubJobCollaboration(),
                screenCapture: screenCapture,
                onJobSubmitted: nil
            )
        )
    }
}

/// VoiceConversationControllerTests のスタブを再利用するための薄いラッパ。
@MainActor
private final class VoiceConversationControllerTestsScriptedSocketFactory: VoiceStreamSocketFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [VoiceConversationCaptureTestsScriptedSocket] = []

    func queue(_ socket: VoiceConversationCaptureTestsScriptedSocket) {
        lock.lock()
        pending.append(socket)
        lock.unlock()
    }

    func makeSocket(url: URL, token: String) async throws -> any VoiceStreamSocket {
        lock.lock()
        defer { lock.unlock() }
        if pending.isEmpty { return VoiceConversationCaptureTestsScriptedSocket() }
        return pending.removeFirst()
    }
}

private final class VoiceConversationControllerTestsStubMic: MicCapturing {
    var onChunk: (@Sendable (Data, Float) -> Void)?
    var isRunning: Bool { false }
    func start() throws {}
    func stop() {}
}

private struct VoiceConversationControllerTestsStubJobCollaboration: VoiceJobCollaborating {
    func submitJob(title: String, body: String) async throws -> JobRequestResponse {
        JobRequestResponse(jobID: "job-1", status: "queued")
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
        RoomJobDetail(jobID: jobID, title: "test", status: "running")
    }
    func listRunning() async throws -> [RoomJobDetail] { [] }
}
