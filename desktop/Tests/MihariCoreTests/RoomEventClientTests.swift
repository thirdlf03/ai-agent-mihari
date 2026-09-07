import Foundation
import Testing

@testable import MihariCore

/// 部屋の REST(照会・追記・中断)と SSE の組み立てが契約どおりかを、通信なしで確かめる。
///
/// 差し替えの通信路を静的に共有するため、直列に実行する。
@Suite("部屋の REST の送信", .serialized)
@MainActor
struct RoomEventClientTests {

    /// 受けた要求を記録し、決めた応答を返す差し替え。
    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        /// 受けた要求の検証と応答を決める。未設定なら空の成功応答。
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        /// 最後に受けた要求。
        nonisolated(unsafe) static var lastRequest: URLRequest?
        /// 最後に受けた本文。
        nonisolated(unsafe) static var lastBody: Data?

        override class func canInit(with request: URLRequest) -> Bool { true }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
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

    /// 差し替えの通信路を REST と SSE の両方に通すクライアントを作る。
    private func makeClient(token: String = "部屋の合言葉") -> RoomEventClient {
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
        StubURLProtocol.lastBody = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let streaming = URLSession(configuration: configuration)
        return RoomEventClient(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            token: token,
            session: session,
            streamingSession: streaming
        )
    }

    /// 送った JSON を辞書として読む。
    private func sentJSON() throws -> [String: Any] {
        let body = try #require(StubURLProtocol.lastBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test("GET /jobs/running に合言葉を載せて引く")
    func listsRunningJobs() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"jobs":[{"job_id":"abc","status":"running"}]}"#.utf8))
        }

        let jobs = try await client.listRunning()

        let sent = try #require(StubURLProtocol.lastRequest)
        #expect(sent.httpMethod == "GET")
        #expect(sent.url?.path == "/jobs/running")
        #expect(sent.value(forHTTPHeaderField: DaemonClient.tokenHeader) == "部屋の合言葉")
        #expect(jobs.map(\.jobID) == ["abc"])
    }

    @Test("GET /jobs/{id} で詳細を引く")
    func fetchesDetail() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"job_id":"abc","title":"掃除"}"#.utf8))
        }

        let detail = try await client.detail(jobID: "abc")

        let sent = try #require(StubURLProtocol.lastRequest)
        #expect(sent.url?.path == "/jobs/abc")
        #expect(detail.title == "掃除")
    }

    @Test("POST /jobs/{id}/followup に本文と依頼者を送る")
    func postsFollowup() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"job_id":"abc","status":"running"}"#.utf8))
        }

        let result = try await client.followup(jobID: "abc", body: "もっと調べて", requestedBy: "pet")

        let sent = try #require(StubURLProtocol.lastRequest)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path == "/jobs/abc/followup")
        #expect(sent.value(forHTTPHeaderField: DaemonClient.tokenHeader) == "部屋の合言葉")
        let json = try sentJSON()
        #expect(json["body"] as? String == "もっと調べて")
        #expect(json["requested_by"] as? String == "pet")
        #expect(result.jobID == "abc")
    }

    @Test("followup の依頼者が無ければ requested_by を送らない")
    func followupWithoutRequester() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("{}".utf8))
        }

        _ = try await client.followup(jobID: "abc", body: "もう一度")

        let json = try sentJSON()
        #expect(json["body"] as? String == "もう一度")
        #expect(json["requested_by"] == nil)
    }

    @Test("POST /jobs/{id}/cancel で中断を送る")
    func postsCancel() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"job_id":"abc","status":"cancelled"}"#.utf8))
        }

        let result = try await client.cancel(jobID: "abc")

        let sent = try #require(StubURLProtocol.lastRequest)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path == "/jobs/abc/cancel")
        #expect(sent.value(forHTTPHeaderField: DaemonClient.tokenHeader) == "部屋の合言葉")
        #expect(result.status == "cancelled")
    }

    @Test("部屋がエラーを返したらその内容を持って投げる")
    func throwsOnErrorStatus() async {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"detail":"仕事がない"}"#.utf8))
        }

        await #expect(throws: RoomError.requestFailed(status: 404, message: "仕事がない")) {
            try await client.detail(jobID: "nope")
        }
    }

    @Test("SSE は /jobs/{id}/events を Accept 付きで開き、Last-Event-ID を載せる")
    func eventStreamCarriesLastEventID() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        _ = try await client.openEventStream(jobID: "abc", lastEventID: "ev-9")

        let sent = try #require(StubURLProtocol.lastRequest)
        #expect(sent.url?.path == "/jobs/abc/events")
        #expect(sent.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(sent.value(forHTTPHeaderField: "Last-Event-ID") == "ev-9")
        #expect(sent.value(forHTTPHeaderField: DaemonClient.tokenHeader) == "部屋の合言葉")
    }

    @Test("GET /jobs/{id}/memory に合言葉を載せて引く")
    func listsMemory() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (
                response,
                Data(
                    #"{"candidates":[{"id":"c1","target":"MEMORY.md","content":"深煎りが好き","status":"pending","created_at":1757073600}]}"#
                        .utf8
                )
            )
        }

        let candidates = try await client.listMemory(jobID: "abc")

        let sent = try #require(StubURLProtocol.lastRequest)
        #expect(sent.httpMethod == "GET")
        #expect(sent.url?.path == "/jobs/abc/memory")
        #expect(sent.value(forHTTPHeaderField: DaemonClient.tokenHeader) == "部屋の合言葉")
        #expect(candidates.first?.content == "深煎りが好き")
    }

    @Test("POST /jobs/{id}/memory/{candidate}/approve|reject は空の JSON で送る")
    func decidesMemory() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("{}".utf8))
        }

        try await client.approveMemory(jobID: "abc", candidateID: "c1")
        var sent = try #require(StubURLProtocol.lastRequest)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path == "/jobs/abc/memory/c1/approve")
        #expect(sent.value(forHTTPHeaderField: DaemonClient.tokenHeader) == "部屋の合言葉")

        try await client.rejectMemory(jobID: "abc", candidateID: "c2")
        sent = try #require(StubURLProtocol.lastRequest)
        #expect(sent.url?.path == "/jobs/abc/memory/c2/reject")
    }

    @Test("POST /jobs/{id}/artifacts/{version}/rollback は空の JSON で送る")
    func postsRollback() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (
                response,
                Data(#"{"id":"art-abc-v3","version":3,"kind":"web"}"#.utf8)
            )
        }

        let manifest = try await client.rollbackArtifact(jobID: "abc", version: "1")
        let sent = try #require(StubURLProtocol.lastRequest)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path == "/jobs/abc/artifacts/1/rollback")
        #expect(sent.value(forHTTPHeaderField: DaemonClient.tokenHeader) == "部屋の合言葉")
        #expect(manifest.artifactID == "art-abc-v3")
    }

    @Test("SSE はカーソルが無ければ Last-Event-ID を載せない")
    func eventStreamWithoutCursor() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        _ = try await client.openEventStream(jobID: "abc", lastEventID: nil)

        let sent = try #require(StubURLProtocol.lastRequest)
        #expect(sent.value(forHTTPHeaderField: "Last-Event-ID") == nil)
    }
}
