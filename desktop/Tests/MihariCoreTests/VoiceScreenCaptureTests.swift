import CoreGraphics
import Foundation
import Testing

@testable import MihariCore

/// コントローラが @MainActor なので、スイートも MainActor で回す。
@Suite("voice 画面キャプチャ")
@MainActor
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

    @Test("display は bounds と title を返す")
    func selectsDisplayBounds() {
        let displays = [
            MouseDisplayBounds(displayID: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), title: "左"),
            MouseDisplayBounds(displayID: 2, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080), title: "右"),
        ]
        let selected = MouseDisplaySelector.display(at: CGPoint(x: 2000, y: 500), displays: displays)
        #expect(selected?.displayID == 2)
        #expect(selected?.title == "右")
    }

    @Test("input.image フレームを契約どおり組み立てる")
    func buildsInputImageFrame() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let text = try VoiceOutgoingFrame.inputImage(data: png, prompt: "画面を見て")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(json["type"] as? String == "input.image")
        #expect(json["image_base64"] as? String == png.base64EncodedString())
        #expect(json["media_type"] as? String == "image/png")
        #expect(json["prompt"] as? String == "画面を見て")
        #expect(json["create_response"] as? Bool == true)
    }

    @Test("input.image は mediaType を指定できる（JPEG）")
    func buildsInputImageFrameWithJPEG() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let text = try VoiceOutgoingFrame.inputImage(data: jpeg, prompt: "見て", mediaType: "image/jpeg")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(json["image_base64"] as? String == jpeg.base64EncodedString())
        #expect(json["media_type"] as? String == "image/jpeg")
    }

    @Test("縮小 JPEG は大きい画像を目標バイト以下に収める")
    func downscaleJPEGFitsByteBudget() throws {
        // 圧縮が効かないノイズ画像を種固定で作る。320px でも 12KB を超えるサイズ。
        var generator = SeededGenerator(seed: 42)
        let width = 1600
        let height = 1200
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in bytes.indices {
            bytes[index] = UInt8(truncatingIfNeeded: generator.next())
        }
        let context = try #require(
            CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        )
        let image = try #require(context.makeImage())
        let png = try CaptureImageCodec.pngData(from: image)

        let jpeg = try #require(VoiceScreenDownscaleJPEG.jpegData(from: png, maxBytes: 12_000))

        #expect(jpeg.count <= 12_000)
        // JPEG マジック（FF D8 FF）で始まる。
        #expect(jpeg.prefix(3).elementsEqual([0xFF, 0xD8, 0xFF]))
    }

    @Test("デコードできない画像データは nil を返す")
    func downscaleJPEGRejectsUndecodableData() {
        #expect(VoiceScreenDownscaleJPEG.jpegData(from: Data([0x00, 0x01])) == nil)
    }

    @Test("スタブでマウスディスプレイを撮って送る")
    func captureAndSendUsesMouseDisplay() async throws {
        // サムネイル生成が通るよう、実際にデコードできる 1x1 PNG を使う。
        let png = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )!
        let socket = VoiceConversationCaptureTestsScriptedSocket()
        let factory = VoiceConversationControllerTestsScriptedSocketFactory()
        factory.queue(socket)
        let controller = VoiceConversationCaptureTests.makeController(
            factory: factory,
            screenCapture: StubVoiceScreenCapture(
                result: VoiceScreenCaptureResult(pngData: png, displayTitle: "右", displayID: 2)
            )
        )
        controller.start()
        // ソケットが開く前に送ろうとすると捨てられるため、接続を待ってから要求する。
        await settle(until: { factory.makeCount >= 1 })
        socket.feed(#"{"type":"session.ready","session_id":"sess-test","model":"mini"}"#)
        controller.captureAndSendScreen(prompt: "見て")
        // 送信と、サムネイル付きの履歴追加の両方が済むまで待つ。
        await settle(until: {
            socket.sent.contains { $0.contains("\"input.image\"") }
                && controller.messages.contains { $0.imageThumbnailPNG != nil }
        })

        let imageFrames = socket.sent.compactMap { text -> [String: Any]? in
            guard
                let data = text.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                json["type"] as? String == "input.image"
            else { return nil }
            return json
        }
        let imageFrame = try #require(imageFrames.first)
        #expect(imageFrame["prompt"] as? String == "見て")
        // text モードでは従来どおり PNG を送る。
        #expect(imageFrame["media_type"] as? String == "image/png")
        #expect(controller.messages.contains(where: { $0.imageThumbnailPNG != nil }))
        controller.stop()
    }

    @Test("live_audio では縮小 JPEG を image/jpeg で送る")
    func liveAudioCaptureSendsJPEG() async throws {
        let png = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )!
        let socket = VoiceConversationCaptureTestsScriptedSocket()
        let factory = VoiceConversationControllerTestsScriptedSocketFactory()
        factory.queue(socket)
        let controller = VoiceConversationCaptureTests.makeController(
            factory: factory,
            screenCapture: StubVoiceScreenCapture(
                result: VoiceScreenCaptureResult(pngData: png, displayTitle: "Main", displayID: 1)
            )
        )
        controller.start()
        await settle(until: { factory.makeCount >= 1 })
        // output_modalities に audio を含む live_audio セッションにする。
        socket.feed(
            #"{"type":"session.ready","session_id":"sess-test","model":"gpt-live-1","output_modalities":["audio","text"]}"#
        )
        await settle(until: { controller.connectionState == .ready })

        controller.captureAndSendScreen(prompt: "見て")
        await settle(until: {
            socket.sent.contains { $0.contains("\"input.image\"") }
        })

        let imageFrame = socket.sent.compactMap { text -> [String: Any]? in
            guard
                let data = text.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                json["type"] as? String == "input.image"
            else { return nil }
            return json
        }.first
        let frame = try #require(imageFrame)
        #expect(frame["media_type"] as? String == "image/jpeg")
        let sentData = try #require(
            (frame["image_base64"] as? String).flatMap { Data(base64Encoded: $0) }
        )
        // JPEG マジックで始まり、目標バイト数に収まる。
        #expect(sentData.prefix(3).elementsEqual([0xFF, 0xD8, 0xFF]))
        #expect(sentData.count <= 12_000)
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
        factory: VoiceConversationControllerTestsScriptedSocketFactory,
        screenCapture: any VoiceScreenCapturing
    ) -> VoiceConversationController {
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
                pcmPlayer: VoiceConversationControllerTestsStubPCMPlayer(),
                onJobSubmitted: nil,
                checkMicPermission: { PermissionState(grant: .granted, detail: "test") },
                requestMicPermission: { true }
            )
        )
    }
}

/// VoiceConversationControllerTests のスタブを再利用するための薄いラッパ。
@MainActor
private final class VoiceConversationControllerTestsScriptedSocketFactory: VoiceStreamSocketFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [VoiceConversationCaptureTestsScriptedSocket] = []
    private var _makeCount = 0

    /// 接続のたびに増える。テストがソケット確立を待つ目印。
    var makeCount: Int { lock.withLock { _makeCount } }

    func queue(_ socket: VoiceConversationCaptureTestsScriptedSocket) {
        lock.lock()
        pending.append(socket)
        lock.unlock()
    }

    func makeSocket(url: URL, token: String) async throws -> any VoiceStreamSocket {
        lock.withLock {
            _makeCount += 1
            if pending.isEmpty { return VoiceConversationCaptureTestsScriptedSocket() }
            return pending.removeFirst()
        }
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
