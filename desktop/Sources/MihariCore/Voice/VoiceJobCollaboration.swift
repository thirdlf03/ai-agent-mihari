import Foundation

/// §5-3: 会話から仕事を依頼・進捗確認・steer・質問回答する口。
public protocol VoiceJobCollaborating: Sendable {
    func submitJob(title: String, body: String) async throws -> JobRequestResponse
    func steer(jobID: String, instruction: String) async throws -> JobSteerResponse
    func answerQuestion(jobID: String, questionID: String, answer: String) async throws -> JobQuestionAnswerResponse
    func fetchJob(jobID: String) async throws -> RoomJobDetail
    func listRunning() async throws -> [RoomJobDetail]
}

/// `JobRequestClient` + `RoomEventClient` を会話向けにまとめた実装。
public struct LiveVoiceJobCollaboration: VoiceJobCollaborating {
    private let jobClient: JobRequestClient
    private let roomClient: RoomEventClient

    public init(jobClient: JobRequestClient, roomClient: RoomEventClient) {
        self.jobClient = jobClient
        self.roomClient = roomClient
    }

    public static func makeFromEnvironment(session: URLSession = .shared) -> LiveVoiceJobCollaboration {
        LiveVoiceJobCollaboration(
            jobClient: JobRequestClient.makeFromEnvironment(session: session),
            roomClient: RoomEventClient.makeFromEnvironment(session: session)
        )
    }

    public func submitJob(title: String, body: String) async throws -> JobRequestResponse {
        try await jobClient.submit(title: title, body: body)
    }

    public func steer(jobID: String, instruction: String) async throws -> JobSteerResponse {
        try await roomClient.steer(jobID: jobID, instruction: instruction)
    }

    public func answerQuestion(
        jobID: String,
        questionID: String,
        answer: String
    ) async throws -> JobQuestionAnswerResponse {
        try await roomClient.answerQuestion(jobID: jobID, questionID: questionID, answer: answer)
    }

    public func fetchJob(jobID: String) async throws -> RoomJobDetail {
        try await roomClient.detail(jobID: jobID)
    }

    public func listRunning() async throws -> [RoomJobDetail] {
        try await roomClient.listRunning()
    }
}

/// `POST /jobs/{id}/steer` の応答（room #47）。
public struct JobSteerResponse: Decodable, Equatable, Sendable {
    public let jobID: String?
    public let seq: Int?
    public let filename: String?
    public let text: String?
    public let createdAt: Date?
    public let delivered: Bool?

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case seq
        case filename
        case text
        case createdAt = "created_at"
        case delivered
    }

    public init(
        jobID: String? = nil,
        seq: Int? = nil,
        filename: String? = nil,
        text: String? = nil,
        createdAt: Date? = nil,
        delivered: Bool? = nil
    ) {
        self.jobID = jobID
        self.seq = seq
        self.filename = filename
        self.text = text
        self.createdAt = createdAt
        self.delivered = delivered
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try container.decodeIfPresent(String.self, forKey: .jobID)
        seq = try container.decodeIfPresent(Int.self, forKey: .seq)
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        delivered = try container.decodeIfPresent(Bool.self, forKey: .delivered)
        if let raw = try container.decodeIfPresent(Double.self, forKey: .createdAt) {
            createdAt = Date(timeIntervalSince1970: raw)
        } else if let raw = try container.decodeIfPresent(Int.self, forKey: .createdAt) {
            createdAt = Date(timeIntervalSince1970: Double(raw))
        } else {
            createdAt = nil
        }
    }
}

/// `POST /jobs/{id}/questions/{qid}/answer` の応答（room #47: `question` ネスト）。
public struct JobQuestionAnswerResponse: Decodable, Equatable, Sendable {
    public let jobID: String?
    public let question: RoomPendingQuestion?

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case question
    }

    public init(jobID: String? = nil, question: RoomPendingQuestion? = nil) {
        self.jobID = jobID
        self.question = question
    }
}

/// room Realtime が desktop へ送るツール名（#40 / Epic #35 想定）。
enum VoiceToolName {
    static let captureScreen = "capture_screen"
    static let submitJob = "submit_job"
    static let steerJob = "steer_job"
    static let getJobStatus = "get_job_status"
    static let showJobQuestion = "show_job_question"

    /// 部屋の実装差を吸収する別名。
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isCaptureScreen(_ name: String) -> Bool {
        switch normalize(name) {
        case captureScreen, "screen_capture", "request_screen", "capture_display":
            return true
        default:
            return false
        }
    }

    static func isSubmitJob(_ name: String) -> Bool {
        switch normalize(name) {
        case submitJob, "create_job", "request_job":
            return true
        default:
            return false
        }
    }

    static func isSteerJob(_ name: String) -> Bool {
        switch normalize(name) {
        case steerJob, "job_steer", "steer":
            return true
        default:
            return false
        }
    }

    static func isGetJobStatus(_ name: String) -> Bool {
        switch normalize(name) {
        case getJobStatus, "check_job_progress", "job_status", "get_job_progress":
            return true
        default:
            return false
        }
    }

    static func isShowJobQuestion(_ name: String) -> Bool {
        switch normalize(name) {
        case showJobQuestion, "job_question", "waiting_for_input", "request_answer":
            return true
        default:
            return false
        }
    }
}

/// `assistant.tool_call` の JSON 引数を読む。
enum VoiceToolArguments {
    static func decode(_ raw: String) -> [String: Any] {
        guard
            let data = raw.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return json
    }

    static func string(_ args: [String: Any], keys: String...) -> String? {
        for key in keys {
            if let value = args[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}

/// ツール呼び出しを会話アクションへ写す。
enum VoiceToolCallHandler {
    enum Action: Equatable, Sendable {
        case captureScreen(prompt: String)
        case submitJob(title: String, body: String)
        case steerJob(jobID: String?, instruction: String)
        case getJobStatus(jobID: String?)
        case showQuestion(jobID: String, questionID: String, prompt: String)
        case unsupported(name: String)
    }

    static func action(for name: String, arguments: String) -> Action {
        let args = VoiceToolArguments.decode(arguments)
        if VoiceToolName.isCaptureScreen(name) {
            let prompt = VoiceToolArguments.string(args, keys: "prompt", "instruction")
                ?? "この画面を見て状況を説明して。"
            return .captureScreen(prompt: prompt)
        }
        if VoiceToolName.isSubmitJob(name) {
            let body = VoiceToolArguments.string(args, keys: "body", "instruction", "request") ?? ""
            let title = VoiceToolArguments.string(args, keys: "title") ?? ""
            return .submitJob(title: title, body: body)
        }
        if VoiceToolName.isSteerJob(name) {
            let instruction = VoiceToolArguments.string(args, keys: "instruction", "body", "message") ?? ""
            let jobID = VoiceToolArguments.string(args, keys: "job_id", "jobID")
            return .steerJob(jobID: jobID, instruction: instruction)
        }
        if VoiceToolName.isGetJobStatus(name) {
            let jobID = VoiceToolArguments.string(args, keys: "job_id", "jobID")
            return .getJobStatus(jobID: jobID)
        }
        if VoiceToolName.isShowJobQuestion(name) {
            let jobID = VoiceToolArguments.string(args, keys: "job_id", "jobID") ?? ""
            let questionID = VoiceToolArguments.string(args, keys: "question_id", "questionID", "qid") ?? ""
            let prompt = VoiceToolArguments.string(args, keys: "prompt", "question", "text") ?? ""
            return .showQuestion(jobID: jobID, questionID: questionID, prompt: prompt)
        }
        return .unsupported(name: name)
    }
}

/// 仕事詳細から `pending_questions` を拾う。
enum VoiceJobQuestionParser {
    static func pendingQuestions(from detail: RoomJobDetail) -> [VoicePendingQuestion] {
        detail.pendingQuestions.compactMap { roomQuestion in
            guard roomQuestion.isPending else { return nil }
            let prompt = roomQuestion.question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !roomQuestion.id.isEmpty, !prompt.isEmpty else { return nil }
            return VoicePendingQuestion(room: roomQuestion, jobID: detail.jobID)
        }
    }

    static func pendingQuestion(from detail: RoomJobDetail) -> VoicePendingQuestion? {
        pendingQuestions(from: detail).first
    }

    static func statusSummary(from detail: RoomJobDetail) -> String {
        let title = detail.title ?? detail.jobID
        let status = detail.status ?? "不明"
        var lines = ["仕事 \(title) (\(detail.jobID))", "状態: \(status)"]
        if let phase = detail.latestEvent?.phase?.label {
            lines.append("位相: \(phase)")
        }
        if let text = detail.latestEvent?.text, !text.isEmpty {
            lines.append(text)
        }
        for pending in pendingQuestions(from: detail) {
            lines.append("質問: \(pending.prompt)")
        }
        return lines.joined(separator: "\n")
    }
}
