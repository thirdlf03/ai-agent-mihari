import Foundation
import Testing

@testable import MihariCore

/// 依頼窓のスクショ添付（#22）。撮影・確認・削除・送信（成功で空に、失敗で残す）の
/// 状態遷移を、通信と ScreenCaptureKit を差し替えて確かめる。
@Suite("依頼窓のスクショ添付", .serialized)
@MainActor
struct JobRequestViewModelTests {

    /// 受けた要求を記録し、決めた応答を返す差し替え。
    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        /// 受けた要求の検証と応答を決める。未設定なら空の成功応答。
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        /// 最後に受けた本文。
        nonisolated(unsafe) static var lastBody: Data?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastBody = request.httpBody ?? Self.drain(stream: request.httpBodyStream)
            do {
                let handler = try Self.handler?(request)
                let (response, data) =
                    handler ?? (
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data("{}".utf8)
                    )
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}

        private static func drain(stream: InputStream?) -> Data? {
            guard let stream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let chunk = 4096
            var buffer = [UInt8](repeating: 0, count: chunk)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: chunk)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }
    }

    /// 差し替えの通信路を通すクライアントを作る。
    private func makeRequestClient() -> JobRequestClient {
        StubURLProtocol.handler = nil
        StubURLProtocol.lastBody = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return JobRequestClient(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            token: "部屋の合言葉",
            session: URLSession(configuration: configuration)
        )
    }

    private func makeRoomClient() -> RoomEventClient {
        StubURLProtocol.handler = nil
        StubURLProtocol.lastBody = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return RoomEventClient(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            token: "部屋の合言葉",
            session: session,
            streamingSession: session
        )
    }

    /// テスト用の撮影対象（Retina のメタデータ付き）。
    private nonisolated(unsafe) static let target = ScreenshotTarget(
        id: "display:1",
        kind: .display,
        title: "Built-in Retina Display (3024×1964)",
        displayID: 1,
        pointWidth: 1512,
        pointHeight: 982,
        pixelWidth: 3024,
        pixelHeight: 1964,
        backingScale: 2.0,
        frameX: 0,
        frameY: 0
    )

    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    private func captureStub(_ target: ScreenshotTarget) async throws -> ScreenshotCapture {
        ScreenshotCapture(
            pngData: Self.png,
            kind: target.kind,
            title: target.title,
            displayID: target.displayID,
            windowID: target.windowID,
            pixelWidth: target.pixelWidth,
            pixelHeight: target.pixelHeight,
            pointWidth: target.pointWidth,
            pointHeight: target.pointHeight,
            backingScale: target.backingScale,
            frameX: target.frameX,
            frameY: target.frameY
        )
    }

    private func makeModel(client: JobRequestClient) -> JobRequestViewModel {
        JobRequestViewModel(
            client: client,
            listTargets: { [Self.target] },
            capture: { try await self.captureStub($0) }
        )
    }

    @Test("対象一覧を読み込み、撮ったスクショを添付・削除できる")
    func capturesAndRemovesAttachment() async {
        let model = makeModel(client: makeRequestClient())
        await model.loadScreenshotTargets()
        #expect(model.screenshotTargets.count == 1)
        #expect(model.captureErrorMessage == nil)

        await model.captureScreenshot(target: Self.target)
        #expect(model.attachments.count == 1)
        #expect(model.attachments[0].pngData == Self.png)
        #expect(model.attachments[0].backingScale == 2.0)
        #expect(model.captureErrorMessage == nil)

        model.removeAttachment(model.attachments[0])
        #expect(model.attachments.isEmpty)
    }

    @Test("権限が無ければ対象一覧の読み込みで理由を表示する")
    func permissionDeniedShowsMessage() async {
        let model = JobRequestViewModel(
            client: makeRequestClient(),
            listTargets: {
                throw CaptureError.screenRecordingPermissionNotGranted(detail: "denied (拒否)")
            },
            capture: { _ in throw CaptureError.screenCaptureFailed(reason: "x") }
        )
        await model.loadScreenshotTargets()
        #expect(model.screenshotTargets.isEmpty)
        #expect(model.captureErrorMessage?.contains("権限") == true)
        #expect(model.messageMentionsPermission == true)
    }

    @Test("撮影に失敗したら理由を表示するだけで落ちない")
    func captureFailureShowsMessage() async {
        let model = JobRequestViewModel(
            client: makeRequestClient(),
            listTargets: { [Self.target] },
            capture: { _ in throw CaptureError.screenCaptureFailed(reason: "権限なしテスト") }
        )
        await model.loadScreenshotTargets()
        await model.captureScreenshot(target: Self.target)
        #expect(model.attachments.isEmpty)
        #expect(model.captureErrorMessage?.contains("取得に失敗") == true)
    }

    @Test("送信が通ったら添付を空にし、失敗したら残す")
    func submitClearsOnSuccessKeepsOnFailure() async {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"job_id":"abc","status":"queued"}"#.utf8))
        }
        let model = makeModel(client: makeRequestClient())
        model.body = "この画面のエラーを見て"
        await model.loadScreenshotTargets()
        await model.captureScreenshot(target: Self.target)

        await model.submit()

        #expect(model.didSucceed == true)
        #expect(model.attachments.isEmpty)
        #expect(model.notice?.contains("スクショ 1 枚") == true)
        // 送信本文にバイト列が載ったことも確かめる。
        let json = try? JSONSerialization.jsonObject(with: StubURLProtocol.lastBody ?? Data()) as? [String: Any]
        let shots = json?["screenshots"] as? [[String: Any]]
        #expect(shots?.count == 1)
        let base64 = shots?[0]["content_base64"] as? String ?? ""
        #expect(Data(base64Encoded: base64) == Self.png)

        // 失敗したら本文も添付も残る。
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"detail":"部屋が落ちてる"}"#.utf8))
        }
        model.body = "もう一度"
        await model.captureScreenshot(target: Self.target)
        await model.submit()

        #expect(model.didSucceed == false)
        #expect(model.attachments.count == 1)
        #expect(model.notice?.contains("部屋が落ちてる") == true)
    }

    @Test("追記にスクショ付きで送れる")
    func followupSendsScreenshots() async {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"job_id":"abc","status":"running"}"#.utf8))
        }
        let model = JobRequestViewModel(
            followupClient: makeRoomClient(),
            jobID: "abc",
            listTargets: { [Self.target] },
            capture: { try await self.captureStub($0) }
        )
        model.body = "この画面も見て"
        await model.loadScreenshotTargets()
        await model.captureScreenshot(target: Self.target)

        await model.submit()

        #expect(model.didSucceed == true)
        #expect(model.attachments.isEmpty)
        #expect(model.notice?.contains("スクショ 1 枚") == true)
        let json = try? JSONSerialization.jsonObject(with: StubURLProtocol.lastBody ?? Data()) as? [String: Any]
        #expect(json?["body"] as? String == "この画面も見て")
        let shots = json?["screenshots"] as? [[String: Any]]
        #expect(shots?.count == 1)
    }
}
