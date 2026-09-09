import Foundation
import Testing

@testable import MihariCore

/// 依頼窓の状態。下書きの復元・保持・削除、添付の上限・形式、二重送信防止、
/// スクショの撮影・確認・削除・送信（成功で空に、失敗で残す）を確かめる。
@Suite("仕事の依頼窓の状態", .serialized)
@MainActor
struct JobRequestViewModelTests {

    /// 受けた要求を記録し、決めた応答を返す差し替え。
    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        /// 受けた要求の検証と応答を決める。未設定なら空の成功応答。
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        /// 最後に受けた本文。
        nonisolated(unsafe) static var lastBody: Data?
        nonisolated(unsafe) static var requestCount = 0
        /// `/jobs` への POST の数。
        nonisolated(unsafe) static var jobRequestCount = 0

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requestCount += 1
            if request.url?.path == "/jobs" {
                Self.jobRequestCount += 1
            }
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
        StubURLProtocol.requestCount = 0
        StubURLProtocol.jobRequestCount = 0
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
        StubURLProtocol.requestCount = 0
        StubURLProtocol.jobRequestCount = 0
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
    private static let target = ScreenshotTarget(
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
            pickScreenshot: { try await self.captureStub(Self.target) }
        )
    }

    /// 差し替えの通信路を通すクライアントと下書き置き場を作る。
    private func makeContext(
        handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? = nil
    ) -> (JobRequestClient, DiskJobRequestDraftStore, URL) {
        StubURLProtocol.handler = handler
        StubURLProtocol.lastBody = nil
        StubURLProtocol.requestCount = 0
        StubURLProtocol.jobRequestCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = JobRequestClient(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            token: "部屋の合言葉",
            session: session
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mihari-test-request-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DiskJobRequestDraftStore(
            fileURL: directory.appendingPathComponent("draft.json")
        )
        return (client, store, directory)
    }

    private func makeStore(_ directory: URL) -> DiskJobRequestDraftStore {
        DiskJobRequestDraftStore(fileURL: directory.appendingPathComponent("draft.json"))
    }

    private func okResponse() -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: URL(string: "http://127.0.0.1:8787/jobs")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!,
            Data(#"{"job_id":"abc","status":"queued"}"#.utf8)
        )
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("待っても条件を満たさなかった")
    }

    // MARK: - スクショ添付（#22）

    @Test("撮ったスクショを添付・削除できる")
    func capturesAndRemovesAttachment() async {
        let model = makeModel(client: makeRequestClient())
        await model.captureScreenshot()
        #expect(model.screenshots.count == 1)
        #expect(model.screenshots[0].pngData == Self.png)
        #expect(model.screenshots[0].backingScale == 2.0)
        #expect(model.captureErrorMessage == nil)

        model.removeScreenshot(model.screenshots[0])
        #expect(model.screenshots.isEmpty)
    }

    @Test("権限が無ければ撮影で理由を表示する")
    func permissionDeniedShowsMessage() async {
        let model = JobRequestViewModel(
            client: makeRequestClient(),
            pickScreenshot: {
                throw CaptureError.screenRecordingPermissionNotGranted(detail: "denied (拒否)")
            }
        )
        await model.captureScreenshot()
        #expect(model.screenshots.isEmpty)
        #expect(model.captureErrorMessage?.contains("権限") == true)
        #expect(model.messageMentionsPermission == true)
    }

    @Test("撮影に失敗したら理由を表示するだけで落ちない")
    func captureFailureShowsMessage() async {
        let model = JobRequestViewModel(
            client: makeRequestClient(),
            pickScreenshot: { throw CaptureError.screenCaptureFailed(reason: "権限なしテスト") }
        )
        await model.captureScreenshot()
        #expect(model.screenshots.isEmpty)
        #expect(model.captureErrorMessage?.contains("取得に失敗") == true)
    }

    @Test("対象選びを閉じたら添付もエラーも残さない")
    func pickerCancelLeavesStateClean() async {
        let model = JobRequestViewModel(
            client: makeRequestClient(),
            pickScreenshot: { throw CancellationError() }
        )
        await model.captureScreenshot()
        #expect(model.screenshots.isEmpty)
        #expect(model.captureErrorMessage == nil)
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
        await model.captureScreenshot()

        await model.submit()

        #expect(model.didSucceed == true)
        #expect(model.screenshots.isEmpty)
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
        await model.captureScreenshot()
        await model.submit()

        #expect(model.didSucceed == false)
        #expect(model.screenshots.count == 1)
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
            pickScreenshot: { try await self.captureStub(Self.target) }
        )
        model.body = "この画面も見て"
        await model.captureScreenshot()

        await model.submit()

        #expect(model.didSucceed == true)
        #expect(model.screenshots.isEmpty)
        #expect(model.notice?.contains("スクショ 1 枚") == true)
        let json = try? JSONSerialization.jsonObject(with: StubURLProtocol.lastBody ?? Data()) as? [String: Any]
        #expect(json?["body"] as? String == "この画面も見て")
        let shots = json?["screenshots"] as? [[String: Any]]
        #expect(shots?.count == 1)
    }

    // MARK: - タイトルの自動生成・任意編集

    @Test("本文の先頭行からタイトルを自動生成し、手入力すると固定される")
    func autoTitleFollowsBodyUntilEdited() {
        let (client, store, _) = makeContext()
        let model = JobRequestViewModel(client: client, draftStore: store)

        model.setBody("先頭行が題になる\n二行目は入らない")
        #expect(model.title == "先頭行が題になる")
        #expect(model.autoTitle)

        model.setTitle("手入力の題")
        #expect(!model.autoTitle)
        model.setBody("本文が変わっても")
        #expect(model.title == "手入力の題")

        model.enableAutoTitle()
        #expect(model.title == "本文が変わっても")
        #expect(model.autoTitle)
    }

    @Test("入力例は本文にサンプルを入れ、タイトルも自動生成に戻す")
    func applyExampleFillsBody() {
        let (client, store, _) = makeContext()
        let model = JobRequestViewModel(client: client, draftStore: store)

        model.setTitle("古い題")
        model.applyExample(.research)
        #expect(model.body.contains("調べてほしいこと"))
        #expect(model.autoTitle)
        #expect(model.title == JobRequestClient.resolveTitle(title: "", body: model.body))
    }

    // MARK: - 添付の上限・形式

    @Test("形式の違う添付は拒否する")
    func rejectsWrongExtension() {
        let (client, store, _) = makeContext()
        let model = JobRequestViewModel(client: client, draftStore: store)

        model.addAttachment(JobAttachment(fileName: "悪意.exe", data: Data("MZ".utf8)))
        #expect(model.attachments.isEmpty)
        #expect(model.attachmentError?.contains("形式") == true)
    }

    @Test("1 個の上限（20MB）を超える添付は拒否する")
    func rejectsOversizedSingleFile() {
        let (client, store, _) = makeContext()
        let model = JobRequestViewModel(client: client, draftStore: store)

        model.addAttachment(
            JobAttachment(
                fileName: "big.png",
                data: Data(count: JobAttachmentLimit.maxFileBytes + 1)
            )
        )
        #expect(model.attachments.isEmpty)
        #expect(model.attachmentError?.contains("20MB") == true)
    }

    @Test("個数上限（10 個）を超える添付は拒否する")
    func rejectsTooManyFiles() {
        let (client, store, _) = makeContext()
        let model = JobRequestViewModel(client: client, draftStore: store)

        for index in 0..<JobAttachmentLimit.maxCount {
            model.addAttachment(
                JobAttachment(fileName: "a\(index).png", data: Data([1, 2, 3]))
            )
        }
        #expect(model.attachments.count == JobAttachmentLimit.maxCount)

        model.addAttachment(JobAttachment(fileName: "extra.png", data: Data([4])))
        #expect(model.attachments.count == JobAttachmentLimit.maxCount)
        #expect(model.attachmentError?.contains("10") == true)
    }

    @Test("合計の上限（50MB）を超える添付は拒否する")
    func rejectsTotalTooLarge() {
        let (client, store, _) = makeContext()
        let model = JobRequestViewModel(client: client, draftStore: store)
        let perFile = 6 * 1024 * 1024

        for index in 0..<8 {
            model.addAttachment(
                JobAttachment(fileName: "a\(index).png", data: Data(count: perFile))
            )
        }
        #expect(model.attachments.count == 8)

        model.addAttachment(JobAttachment(fileName: "a8.png", data: Data(count: perFile)))
        #expect(model.attachments.count == 8)
        #expect(model.attachmentError?.contains("50MB") == true)
    }

    @Test("添付は削除できる")
    func removesAttachment() {
        let (client, store, _) = makeContext()
        let model = JobRequestViewModel(client: client, draftStore: store)

        model.addAttachment(JobAttachment(fileName: "a.png", data: Data([1])))
        model.addAttachment(JobAttachment(fileName: "b.md", data: Data("#".utf8)))
        model.removeAttachment(at: 0)
        #expect(model.attachments.map(\.fileName) == ["b.md"])
    }

    // MARK: - 二重送信防止

    @Test("送信中は二重に送らない")
    func doubleSubmitSendsOnce() async throws {
        // 応答を少し遅らせて、送信中の判定を観測できるようにする。
        let (client, store, _) = makeContext { _ in
            Thread.sleep(forTimeInterval: 0.4)
            return (
                HTTPURLResponse(
                    url: URL(string: "http://127.0.0.1:8787/jobs")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"job_id":"abc","status":"queued"}"#.utf8)
            )
        }
        let model = JobRequestViewModel(client: client, draftStore: store)
        model.setBody("やること")

        let first = Task { await model.submit() }
        try await Task.sleep(for: .milliseconds(80))
        #expect(model.isSubmitting)
        #expect(!model.canSubmit)
        let second = Task { await model.submit() }
        _ = await first.value
        _ = await second.value

        #expect(StubURLProtocol.jobRequestCount == 1)
        #expect(model.didSucceed)
    }

    // MARK: - 下書きの復元・保持・削除

    @Test("下書きから本文・タイトル・添付を復元する")
    func restoresDraft() throws {
        let (_, store, directory) = makeContext()
        let file = directory.appendingPathComponent("図.png")
        try Data([0x89, 0x50]).write(to: file)
        try store.save(
            JobRequestDraft(
                body: "続きから書く",
                title: "もとの題",
                autoTitle: true,
                attachments: [
                    DraftAttachment(
                        fileName: "図.png",
                        storedPath: file.path,
                        size: 2,
                        fileExtension: "png"
                    )
                ],
                settings: ["autoTitle": "true"]
            )
        )

        let (client, _, _) = makeContext()
        let model = JobRequestViewModel(client: client, draftStore: store)
        #expect(model.body == "続きから書く")
        #expect(model.attachments.map(\.fileName) == ["図.png"])
        #expect(model.attachments.first?.data == Data([0x89, 0x50]))
    }

    @Test("送信に失敗したら下書きを保持する")
    func failedSubmitKeepsDraft() async throws {
        let (client, store, _) = makeContext { _ in
            (
                HTTPURLResponse(
                    url: URL(string: "http://127.0.0.1:8787/jobs")!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"detail":"部屋が落ちた"}"#.utf8)
            )
        }
        let model = JobRequestViewModel(client: client, draftStore: store)
        model.setBody("やること")

        await model.submit()

        #expect(!model.didSucceed)
        #expect(model.notice?.contains("部屋が落ちた") == true)
        let draft = try store.load()
        #expect(draft?.body == "やること")
    }

    @Test("送信に成功したら下書きを消してジョブ詳細を開く")
    func successClearsDraftAndCallsOnSubmitted() async throws {
        var submitted: (String, String)?
        let (client, store, _) = makeContext { _ in self.okResponse() }
        let model = JobRequestViewModel(
            client: client,
            onSubmitted: { jobID, title in submitted = (jobID, title) },
            draftStore: store
        )
        model.setBody("頼む")
        model.setTitle("掃除")

        await model.submit()

        #expect(model.didSucceed)
        #expect(model.body.isEmpty)
        #expect(submitted?.0 == "abc")
        #expect(submitted?.1 == "掃除")
        #expect(try store.load() == nil)
    }

    // MARK: - capabilities

    @Test("部屋が添付に対応していれば添付 UI を出す")
    func supportsAttachmentsWhenBackendAllows() async throws {
        let (client, store, _) = makeContext { _ in
            (
                HTTPURLResponse(
                    url: URL(string: "http://127.0.0.1:8787/capabilities")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"attachment_upload":true,"job_list":true}"#.utf8)
            )
        }
        let model = JobRequestViewModel(client: client, draftStore: store)
        try await eventually { model.supportsAttachments }
    }

    @Test("旧バックエンド（404）なら添付 UI を出さない")
    func hidesAttachmentsOnOldBackend() async throws {
        let (client, store, _) = makeContext { _ in
            (
                HTTPURLResponse(
                    url: URL(string: "http://127.0.0.1:8787/capabilities")!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"detail":"ない"}"#.utf8)
            )
        }
        let model = JobRequestViewModel(client: client, draftStore: store)
        try await eventually { !model.supportsAttachments }
    }
}
