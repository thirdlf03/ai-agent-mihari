import Foundation
import Testing

@testable import MihariCore

@Suite("voice 仕事連携", .serialized)
struct VoiceJobCollaborationTests {

    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        nonisolated(unsafe) static var lastRequest: URLRequest?
        nonisolated(unsafe) static var lastBody: Data?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastRequest = request
            Self.lastBody = request.httpBody
            do {
                let (response, data) = try Self.handler?(request)
                    ?? (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeSession() -> URLSession {
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
        StubURLProtocol.lastBody = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test("steer は POST /jobs/{id}/steer に instruction を送る")
    func steerPostsInstruction() async throws {
        let session = makeSession()
        StubURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/jobs/job-9/steer")
            #expect(request.value(forHTTPHeaderField: DaemonClient.tokenHeader) == "tok")
            let body = try #require(request.httpBody)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["instruction"] as? String == "もっと短く")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"job_id":"job-9","status":"running"}"#.utf8))
        }
        let client = RoomEventClient(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            token: "tok",
            session: session
        )
        let result = try await client.steer(jobID: "job-9", instruction: "もっと短く")
        #expect(result.jobID == "job-9")
        #expect(result.status == "running")
    }

    @Test("answer は POST /jobs/{id}/questions/{qid}/answer に answer を送る")
    func answerPostsBody() async throws {
        let session = makeSession()
        StubURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/jobs/job-9/questions/q1/answer")
            let body = try #require(request.httpBody)
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["answer"] as? String == "A案")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"job_id":"job-9","question_id":"q1","status":"running"}"#.utf8))
        }
        let client = RoomEventClient(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            token: "tok",
            session: session
        )
        let result = try await client.answerQuestion(jobID: "job-9", questionID: "q1", answer: "A案")
        #expect(result.questionID == "q1")
    }

    @Test("ツール名と引数を会話アクションへ写す")
    func mapsToolCalls() {
        let capture = VoiceToolCallHandler.action(
            for: "capture_screen",
            arguments: #"{"prompt":"今の画面"}"#
        )
        #expect(capture == .captureScreen(prompt: "今の画面"))

        let steer = VoiceToolCallHandler.action(
            for: "steer_job",
            arguments: #"{"job_id":"j1","instruction":"急いで"}"#
        )
        #expect(steer == .steerJob(jobID: "j1", instruction: "急いで"))

        let question = VoiceToolCallHandler.action(
            for: "show_job_question",
            arguments: #"{"job_id":"j1","question_id":"q2","prompt":"どれ？"}"#
        )
        #expect(question == .showQuestion(jobID: "j1", questionID: "q2", prompt: "どれ？"))
    }

    @Test("waiting_for_input の質問を detail から拾う")
    func parsesPendingQuestion() {
        let detail = RoomJobDetail(
            jobID: "j1",
            title: "調査",
            status: "waiting_for_input",
            pendingQuestionID: "q1",
            pendingQuestionText: "続けますか？"
        )
        let pending = VoiceJobQuestionParser.pendingQuestion(from: detail)
        #expect(pending?.questionID == "q1")
        #expect(pending?.prompt == "続けますか？")
    }
}
