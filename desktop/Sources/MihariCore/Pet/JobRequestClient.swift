import Foundation

/// 作業部屋 (room) へ仕事を投げる口。
///
/// 部屋の HTTP 契約(`room/src/mihari_room/contracts.py`)では `POST /jobs` に
/// `{"title", "body", "source"}` を送り、`X-Mihari-Token` で認証する。
/// ヘッダ名は `DaemonClient.tokenHeader` と同じものを使う。
public struct JobRequestClient: Sendable {

    /// VPS の部屋の URL を決める環境変数。
    public static let roomURLEnvironmentKey = "MIHARI_ROOM_URL"
    /// VPS の部屋のトークンを決める環境変数。
    public static let roomTokenEnvironmentKey = "MIHARI_ROOM_TOKEN"
    /// 環境変数が無いときの行き先。手元の部屋。
    public static let defaultRoomURLString = "http://127.0.0.1:8787"

    /// 接続先はここだけが知っている。環境変数があれば VPS、無ければ手元。
    public static var defaultBaseURL: URL {
        let raw =
            ProcessInfo.processInfo.environment[roomURLEnvironmentKey]
            ?? defaultRoomURLString
        return URL(string: raw) ?? URL(string: defaultRoomURLString)!
    }

    /// 部屋のトークンはここだけが知っている。未設定なら空文字。
    public static func defaultToken() -> String {
        ProcessInfo.processInfo.environment[roomTokenEnvironmentKey] ?? ""
    }

    /// 環境変数から組み立てたクライアント。画面から使うときはこれでよい。
    public static func makeFromEnvironment(session: URLSession = .shared) -> JobRequestClient {
        JobRequestClient(baseURL: defaultBaseURL, token: defaultToken(), session: session)
    }

    private let baseURL: URL
    private let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    /// タイトルが空なら本文の先頭行から作る(最大 100 文字)。
    ///
    /// 前後の空白だけのタイトルも「空」とみなす。
    public static func resolveTitle(title: String, body: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        let firstLine =
            body.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init)
            ?? ""
        return String(firstLine.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
    }

    /// 仕事を 1 件頼む。タイトルが空なら本文の先頭行から作る。
    @discardableResult
    public func submit(title: String, body: String) async throws -> JobRequestResponse {
        guard let url = URL(string: "jobs", relativeTo: baseURL) else {
            throw JobRequestError.invalidURL(path: "jobs")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: DaemonClient.tokenHeader)
        request.httpBody = try JSONEncoder().encode(
            JobRequestPayload(title: Self.resolveTitle(title: title, body: body), body: body)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw JobRequestError.requestFailed(status: 0, message: error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw JobRequestError.requestFailed(status: status, message: Self.detail(from: data))
        }
        do {
            return try JSONDecoder().decode(JobRequestResponse.self, from: data)
        } catch {
            throw JobRequestError.requestFailed(
                status: status,
                message: "応答を解釈できない: \(error.localizedDescription)"
            )
        }
    }

    private static func detail(from data: Data) -> String {
        if let payload = try? JSONDecoder().decode(JobRequestErrorPayload.self, from: data) {
            return payload.detail
        }
        let raw =
            String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        return raw.isEmpty ? "詳細なし" : raw
    }

    /// `POST /jobs` の本文。`source` はつねに `pet`。
    private struct JobRequestPayload: Encodable {
        let title: String
        let body: String
        let source: String

        init(title: String, body: String) {
            self.title = title
            self.body = body
            self.source = "pet"
        }
    }

    /// 失敗の応答。本文の `detail` だけ読む。
    private struct JobRequestErrorPayload: Decodable {
        let detail: String
    }
}

/// `POST /jobs` の応答。部屋側の実装が多少変わっても読めるよう、全部任意にする。
public struct JobRequestResponse: Decodable, Equatable, Sendable {
    public let jobID: String?
    public let threadID: Int?
    public let status: String?

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case threadID = "thread_id"
        case status
    }

    public init(jobID: String? = nil, threadID: Int? = nil, status: String? = nil) {
        self.jobID = jobID
        self.threadID = threadID
        self.status = status
    }
}

/// 依頼窓からの送信で起きる失敗。
public enum JobRequestError: Error, Equatable, Sendable {
    /// URL を組み立てられない。
    case invalidURL(path: String)
    /// 通信できない、部屋がエラーを返す、応答を読めない。
    case requestFailed(status: Int, message: String)
}

extension JobRequestError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL(let path):
            return "URL を組み立てられない: \(path)"
        case .requestFailed(let status, let message):
            return status == 0 ? message : "部屋がエラーを返した (\(status)): \(message)"
        }
    }
}
