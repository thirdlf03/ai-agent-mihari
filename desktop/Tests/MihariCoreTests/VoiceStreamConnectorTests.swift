import Foundation
import Testing

@testable import MihariCore

@Suite("voice ストリーム接続", .serialized)
struct VoiceStreamConnectorTests {

    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
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

    private final class NullSocketFactory: VoiceStreamSocketFactory, @unchecked Sendable {
        func makeSocket(url: URL, token: String) async throws -> any VoiceStreamSocket {
            struct NullSocket: VoiceStreamSocket {
                func send(_ text: String) async throws {}
                func receive() async throws -> String? { nil }
                func close() async {}
            }
            return NullSocket()
        }
    }

    private func makeConnector() -> VoiceStreamConnector {
        StubURLProtocol.handler = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let endpoint = VoiceSessionEndpoint(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            token: "token"
        )
        return VoiceStreamConnector(
            client: VoiceSessionClient(endpoint: endpoint, session: session),
            socketFactory: NullSocketFactory(),
            endpoint: endpoint
        )
    }

    @Test("closed セッションへの tryReconnect は nil")
    func tryReconnectReturnsNilForClosedSession() async throws {
        let connector = makeConnector()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = """
            {"session_id":"old","model":"gpt-realtime-2.1-mini","status":"closed","error":null}
            """
            #expect(request.httpMethod == "GET")
            return (response, Data(body.utf8))
        }

        let result = try await connector.tryReconnect(
            sessionID: "old",
            streamPath: "/voice/sessions/old/stream"
        )
        #expect(result == nil)
    }
}
