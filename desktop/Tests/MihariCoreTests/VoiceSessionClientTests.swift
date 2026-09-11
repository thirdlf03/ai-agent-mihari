import Foundation
import Testing

@testable import MihariCore

/// `POST/GET /voice/sessions` が契約どおりかを、通信なしで確かめる。
@Suite("voice セッション API", .serialized)
struct VoiceSessionClientTests {

    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        nonisolated(unsafe) static var lastRequest: URLRequest?

        override class func canInit(with request: URLRequest) -> Bool { true }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastRequest = request
            do {
                let (response, data) = try Self.handler?(request) ?? (
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
    }

    private func makeClient(token: String = "部屋の合言葉") -> VoiceSessionClient {
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return VoiceSessionClient(
            endpoint: VoiceSessionEndpoint(
                baseURL: URL(string: "http://127.0.0.1:8787")!,
                token: token
            ),
            session: session
        )
    }

    @Test("POST /voice/sessions に合言葉を載せ、session_id を読む")
    func createsVoiceSession() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = """
            {"session_id":"sess-1","model":"gpt-realtime-2.1-mini","status":"created",\
            "protocol_version":1,"stream_path":"/voice/sessions/sess-1/stream"}
            """
            return (response, Data(body.utf8))
        }

        let created = try await client.createSession()

        let sent = try #require(StubURLProtocol.lastRequest)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path == "/voice/sessions")
        #expect(sent.value(forHTTPHeaderField: DaemonClient.tokenHeader) == "部屋の合言葉")
        #expect(created.sessionID == "sess-1")
        #expect(created.streamPath == "/voice/sessions/sess-1/stream")
        #expect(created.protocolVersion == 1)
    }

    @Test("GET /voice/sessions/{id} で状態を読む")
    func fetchesSessionStatus() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = """
            {"session_id":"sess-1","model":"gpt-realtime-2.1-mini","status":"streaming","error":null}
            """
            return (response, Data(body.utf8))
        }

        let status = try await client.sessionStatus(sessionID: "sess-1")

        let sent = try #require(StubURLProtocol.lastRequest)
        #expect(sent.httpMethod == "GET")
        #expect(sent.url?.path == "/voice/sessions/sess-1")
        #expect(status.status == "streaming")
        #expect(status.isReconnectable)
    }

    @Test("closed セッションは isReconnectable が false")
    func closedSessionIsNotReconnectable() async throws {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = """
            {"session_id":"sess-1","model":"gpt-realtime-2.1-mini","status":"closed","error":null}
            """
            return (response, Data(body.utf8))
        }

        let status = try await client.sessionStatus(sessionID: "sess-1")
        #expect(status.status == "closed")
        #expect(status.isReconnectable == false)
    }

    @Test("HTTP 401 は requestFailed になる")
    func httpErrorThrowsRequestFailed() async {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = """
            {"detail":"合言葉が違う"}
            """
            return (response, Data(body.utf8))
        }

        await #expect(throws: VoiceSessionError.self) {
            _ = try await client.createSession()
        }
    }
}
