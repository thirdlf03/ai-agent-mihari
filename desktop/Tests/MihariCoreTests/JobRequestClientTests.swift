import Foundation
import Testing

@testable import MihariCore

/// `POST /jobs` の組み立てが部屋の契約どおりかを、通信なしで確かめる。
///
/// 差し替えの通信路を静的に共有するため、直列に実行する。
@Suite("仕事の依頼の送信", .serialized)
struct JobRequestClientTests {

    /// 受けた要求を記録し、決めた応答を返す差し替え。
    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        /// 受けた要求の検証と応答を決める。未設定なら空の成功応答。
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        /// 最後に受けた要求。
        nonisolated(unsafe) static var lastRequest: URLRequest?
        /// 最後に受けた本文。
        nonisolated(unsafe) static var lastBody: Data?
        /// 受けた要求の数。
        nonisolated(unsafe) static var requestCount = 0

        override class func canInit(with request: URLRequest) -> Bool { true }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requestCount += 1
            Self.lastRequest = request
            // URLSession は Data の本文を httpBodyStream に載せ替えて渡してくるため、両方見る。
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

        /// ストリームの中身を全部読む。空なら `nil`。
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

    /// 差し替えの通信路を通すセッションでクライアントを作る。
    private func makeClient(token: String = "部屋の合言葉") -> JobRequestClient {
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
        StubURLProtocol.lastBody = nil
        StubURLProtocol.requestCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return JobRequestClient(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            token: token,
            session: session
        )
    }

    /// 送った JSON を辞書として読む。
    private func sentJSON() throws -> [String: Any] {
        let body = try #require(StubURLProtocol.lastBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test("POST で /jobs に title・body・source=pet を送り、合言葉を載せる")
    func postsJobToJobsPath() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"job_id":"abc","status":"queued"}"#.utf8))
        }

        let response = try await client.submit(title: "掃除", body: "部屋を片付けて")

        let sent = try #require(StubURLProtocol.lastRequest)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path == "/jobs")
        #expect(sent.value(forHTTPHeaderField: DaemonClient.tokenHeader) == "部屋の合言葉")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try sentJSON()
        #expect(json["title"] as? String == "掃除")
        #expect(json["body"] as? String == "部屋を片付けて")
        #expect(json["source"] as? String == "pet")
        #expect(response.jobID == "abc")
        #expect(response.status == "queued")
    }

    @Test("タイトルが空なら本文の先頭行から作る")
    func derivesTitleFromFirstLine() async throws {
        let client = makeClient()

        _ = try await client.submit(title: "  ", body: "先頭行が題になる\n二行目は入らない")

        let json = try sentJSON()
        #expect(json["title"] as? String == "先頭行が題になる")
        #expect(json["body"] as? String == "先頭行が題になる\n二行目は入らない")
    }

    @Test("先頭行が長いときは 100 文字で切る")
    func truncatesDerivedTitle() async throws {
        let client = makeClient()
        let long = String(repeating: "あ", count: 150)

        _ = try await client.submit(title: "", body: long)

        let json = try sentJSON()
        #expect((json["title"] as? String)?.count == 100)
    }

    @Test("タイトルも本文も空なら依頼にする")
    func emptyBodyUsesDefaultTitle() async throws {
        let client = makeClient()

        _ = try await client.submit(title: "", body: "")

        let json = try sentJSON()
        #expect(json["title"] as? String == "依頼")
    }

    @Test("手入力のタイトルも 100 文字で切る")
    func truncatesExplicitTitle() async throws {
        let client = makeClient()
        let long = String(repeating: "あ", count: 150)

        _ = try await client.submit(title: long, body: "本文")

        let json = try sentJSON()
        #expect((json["title"] as? String)?.count == 100)
    }

    @Test("部屋がエラーを返したらその内容を持って投げる")
    func throwsOnErrorStatus() async {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"detail":"合言葉が違う"}"#.utf8))
        }

        await #expect(throws: JobRequestError.requestFailed(status: 401, message: "合言葉が違う")) {
            try await client.submit(title: "掃除", body: "頼む")
        }
    }

    // MARK: - 添付

    @Test("添付は base64 で JSON に載せて送る")
    func sendsAttachmentsAsBase64() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"job_id":"abc","status":"queued"}"#.utf8))
        }
        let png = Data([0x89, 0x50, 0x4E, 0x47])

        _ = try await client.submit(
            title: "図を見て",
            body: "参考にして",
            attachments: [JobAttachment(fileName: "図.png", data: png)]
        )

        let json = try sentJSON()
        let attachments = try #require(json["attachments"] as? [[String: Any]])
        #expect(attachments.count == 1)
        #expect(attachments[0]["name"] as? String == "図.png")
        let content = try #require(attachments[0]["content"] as? String)
        #expect(Data(base64Encoded: content) == png)
    }

    @Test("添付が無ければ attachments を送らない（旧形式のまま）")
    func omitsAttachmentsWhenEmpty() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"job_id":"abc","status":"queued"}"#.utf8))
        }

        _ = try await client.submit(title: "掃除", body: "頼む")

        #expect(try sentJSON()["attachments"] == nil)
    }

    @Test("形式の違う添付は送らずにエラーにする")
    func rejectsInvalidAttachmentBeforeSending() async {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"job_id":"abc","status":"queued"}"#.utf8))
        }

        await #expect(throws: JobAttachmentError.rejectedExtension("悪意.exe")) {
            try await client.submit(
                title: "掃除",
                body: "頼む",
                attachments: [JobAttachment(fileName: "悪意.exe", data: Data("MZ".utf8))]
            )
        }
        #expect(StubURLProtocol.requestCount == 0)
    }

    // MARK: - capabilities

    @Test("対応機能を読める")
    func readsCapabilities() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            #expect(request.url?.path == "/capabilities")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"attachment_upload":true,"job_list":true,"job_history":true}"#.utf8))
        }

        let caps = await client.fetchCapabilities()
        #expect(caps?.supportsAttachments == true)
        #expect(caps?.supportsJobList == true)
    }

    @Test("旧バックエンド（404）では capabilities が nil になる")
    func oldBackendCapabilitiesAreNil() async {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"detail":"ない"}"#.utf8))
        }

        #expect(await client.fetchCapabilities() == nil)
    }
}
