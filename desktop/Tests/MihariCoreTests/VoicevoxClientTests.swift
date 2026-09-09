import Foundation
import Testing

@testable import MihariCore

/// VOICEVOX への `audio_query` → `synthesis` が契約どおりかを、通信なしで確かめる。
@Suite("VOICEVOX 合成クライアント", .serialized)
struct VoicevoxClientTests {

    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        nonisolated(unsafe) static var requests: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requests.append(request)
            do {
                let (response, data) = try Self.handler?(request) ?? (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data()
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

    private func makeClient(
        baseURL: URL = URL(string: "http://127.0.0.1:50021")!,
        speakerID: Int = 14
    ) -> VoicevoxClient {
        StubURLProtocol.handler = nil
        StubURLProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return VoicevoxClient(
            configuration: VoicevoxConfiguration(
                baseURL: baseURL,
                speakerID: speakerID,
                tuning: .standard,
                queryTimeout: 2,
                synthesisTimeout: 8
            ),
            session: session
        )
    }

    private func requestBody(_ request: URLRequest) -> Data? {
        request.httpBody
    }

    @Test("audio_query と synthesis を話者 14 で順に叩き、WAV を返す")
    func synthesizesThroughVoicevoxEndpoints() async throws {
        let client = makeClient()
        let queryJSON = Data(#"{"speedScale":1.0,"intonationScale":1.0}"#.utf8)
        let wav = Data([0x52, 0x49, 0x46, 0x46])

        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            guard let url = request.url else { return (response, Data()) }
            if url.path.hasSuffix("audio_query") {
                return (response, queryJSON)
            }
            if url.path.hasSuffix("synthesis") {
                return (response, wav)
            }
            Issue.record("想定外のパス: \(url.path)")
            return (response, Data())
        }

        let result = try await client.synthesize(text: VoiceConversationSmoke.mockReplyText)

        #expect(result == wav)
        #expect(StubURLProtocol.requests.count == 2)

        let queryRequest = try #require(StubURLProtocol.requests.first)
        #expect(queryRequest.httpMethod == "POST")
        #expect(queryRequest.url?.path.hasSuffix("audio_query") == true)
        #expect(queryRequest.url?.query()?.contains("speaker=14") == true)
        #expect(
            queryRequest.url?.query()?.contains(
                "text=\(VoiceConversationSmoke.mockReplyText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            ) == true
                || queryRequest.url?.absoluteString.contains("text=") == true
        )

        let synthesisRequest = try #require(StubURLProtocol.requests.last)
        #expect(synthesisRequest.httpMethod == "POST")
        #expect(synthesisRequest.url?.path.hasSuffix("synthesis") == true)
        #expect(synthesisRequest.url?.query()?.contains("speaker=14") == true)
        #expect(synthesisRequest.value(forHTTPHeaderField: "Accept") == "audio/wav")
        #expect(synthesisRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let sentQuery = try #require(requestBody(synthesisRequest))
        let tuned = try JSONSerialization.jsonObject(with: sentQuery) as? [String: Any]
        #expect(tuned?["speedScale"] as? Double == VoicevoxQueryTuning.standard.speed)
        #expect(tuned?["intonationScale"] as? Double == VoicevoxQueryTuning.standard.intonation)
    }

    @Test("エンジンが 2xx 以外を返したら失敗する")
    func nonSuccessStatusThrows() async {
        let client = makeClient()
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        await #expect(throws: VoicevoxError.badStatus(503)) {
            _ = try await client.synthesize(text: "テスト")
        }
    }
}
