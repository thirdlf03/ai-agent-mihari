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

    /// URLSession は本文を `httpBodyStream` へ移すことがあるので両方を読む。
    private func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }

    @Test("steer は POST /jobs/{id}/steer に text を送る")
    func steerPostsText() async throws {
        let session = makeSession()
        StubURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/jobs/job-9/steer")
            #expect(request.value(forHTTPHeaderField: DaemonClient.tokenHeader) == "tok")
            let body = try #require(requestBody(request))
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["text"] as? String == "左側を優先して")
            #expect(json["instruction"] == nil)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (
                response,
                Data(
                    """
                    {"job_id":"job-9","seq":1,"filename":"001.txt","text":"左側を優先して",\
                    "created_at":0.0,"delivered":true}
                    """.utf8
                )
            )
        }
        let client = RoomEventClient(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            token: "tok",
            session: session
        )
        let result = try await client.steer(jobID: "job-9", instruction: "左側を優先して")
        #expect(result.jobID == "job-9")
        #expect(result.seq == 1)
        #expect(result.filename == "001.txt")
        #expect(result.text == "左側を優先して")
        #expect(result.delivered == true)
    }

    @Test("answer は POST /jobs/{id}/questions/{qid}/answer に answer を送る")
    func answerPostsBody() async throws {
        let session = makeSession()
        StubURLProtocol.handler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/jobs/job-9/questions/q1/answer")
            let body = try #require(requestBody(request))
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["answer"] as? String == "blue")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (
                response,
                Data(
                    """
                    {"job_id":"job-9","question":{"id":"q1","question":"色は？","choices":["red","blue"],\
                    "multi_select":false,"status":"answered","answer":"blue","created_at":0.0,"answered_at":0.1}}
                    """.utf8
                )
            )
        }
        let client = RoomEventClient(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            token: "tok",
            session: session
        )
        let result = try await client.answerQuestion(jobID: "job-9", questionID: "q1", answer: "blue")
        #expect(result.jobID == "job-9")
        #expect(result.question?.id == "q1")
        #expect(result.question?.status == "answered")
        #expect(result.question?.answer == "blue")
    }

    @Test("GET /jobs/{id} の pending_questions を decode する")
    func decodesPendingQuestionsArray() throws {
        let json = """
        {"job_id":"j1","status":"waiting_for_input","pending_questions":[\
        {"id":"q1","question":"続けますか？","choices":null,"multi_select":false,"status":"pending"},\
        {"id":"q2","question":"色は？","choices":["red","blue"],"multi_select":false,"status":"pending"}\
        ]}
        """
        let detail = try JSONDecoder().decode(RoomJobDetail.self, from: Data(json.utf8))
        #expect(detail.pendingQuestions.count == 2)
        #expect(try #require(detail.pendingQuestions.first).id == "q1")
        #expect(detail.pendingQuestions.dropFirst().first?.choices == ["red", "blue"])
        let pending = VoiceJobQuestionParser.pendingQuestions(from: detail)
        #expect(pending.count == 2)
        #expect(try #require(pending.first).prompt == "続けますか？")
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

    @Test("pending_questions の先頭 pending を拾う")
    func parsesFirstPendingQuestion() throws {
        let detail = RoomJobDetail(
            jobID: "j1",
            title: "調査",
            status: "waiting_for_input",
            pendingQuestions: [
                RoomPendingQuestion(id: "q1", question: "続けますか？", status: "pending"),
                RoomPendingQuestion(id: "q2", question: "色は？", choices: ["red"], status: "answered"),
            ]
        )
        let pending = VoiceJobQuestionParser.pendingQuestions(from: detail)
        #expect(pending.count == 1)
        let first = try #require(pending.first)
        #expect(first.questionID == "q1")
        #expect(first.prompt == "続けますか？")
    }

    @Test("submit_job / get_job_status の別名と引数キーを読む")
    func mapsSubmitAndStatusToolAliases() {
        let submit = VoiceToolCallHandler.action(
            for: "create_job",
            arguments: #"{"title":"調査","body":"README を読んで"}"#
        )
        #expect(submit == .submitJob(title: "調査", body: "README を読んで"))

        let status = VoiceToolCallHandler.action(
            for: "job_status",
            arguments: #"{"job_id":"j9"}"#
        )
        #expect(status == .getJobStatus(jobID: "j9"))
    }

    @Test("steer の別名と instruction / body / message を読む")
    func mapsSteerAliasesAndArgumentKeys() {
        let steer = VoiceToolCallHandler.action(
            for: "steer",
            arguments: #"{"job_id":"j1","message":"左側を優先"}"#
        )
        #expect(steer == .steerJob(jobID: "j1", instruction: "左側を優先"))

        let bodySteer = VoiceToolCallHandler.action(
            for: "steer_job",
            arguments: #"{"body":"急いで"}"#
        )
        #expect(bodySteer == .steerJob(jobID: nil, instruction: "急いで"))
    }

    @Test("statusSummary は title / status / phase / pending をまとめる")
    func buildsStatusSummary() {
        let detail = RoomJobDetail(
            jobID: "j1",
            title: "調査タスク",
            status: "waiting_for_input",
            latestEvent: RoomEvent(
                id: "e1",
                jobID: "j1",
                phase: .researching,
                kind: nil,
                text: "資料を読んでいる"
            ),
            pendingQuestions: [
                RoomPendingQuestion(id: "q1", question: "続けますか？", status: "pending"),
            ]
        )
        let summary = VoiceJobQuestionParser.statusSummary(from: detail)
        #expect(summary.contains("調査タスク"))
        #expect(summary.contains("waiting_for_input"))
        #expect(summary.contains("調査中"))
        #expect(summary.contains("資料を読んでいる"))
        #expect(summary.contains("質問: 続けますか？"))
    }

    @Test("JobSteerResponse の created_at は Int でも decode する")
    func decodesSteerCreatedAtAsInt() throws {
        let json = """
        {"job_id":"j1","seq":2,"text":"急いで","created_at":1700000000,"delivered":true}
        """
        let response = try JSONDecoder().decode(JobSteerResponse.self, from: Data(json.utf8))
        #expect(response.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
    }
}
