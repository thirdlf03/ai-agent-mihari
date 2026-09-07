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

    /// タイトルが空なら本文の先頭の中身がある行から作る(最大 100 文字)。
    /// どちらも空なら Discord が弾く空スレ名を避けるため「依頼」。
    public static func resolveTitle(title: String, body: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return String(trimmed.prefix(100))
        }
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                return String(candidate.prefix(100))
            }
        }
        return "依頼"
    }

    /// 仕事を 1 件頼む。タイトルが空なら本文の先頭行から作る。
    ///
    /// ``allowExternalPublish`` は Temporary Deploy（外部公開）の依頼ごとの明示許可。
    /// 付けない限り部屋は agent へ外部公開の道具を渡さない。
    /// スクショ付きならバイト列（base64）を `screenshots` に載せる。
    ///
    /// 添付は上限（10 個・各 20MB・合計 50MB）と形式（PNG/JPEG/PDF/Markdown/テキスト）
    /// を送る前に検証し、違えば送らずに投げる。
    @discardableResult
    public func submit(
        title: String,
        body: String,
        allowExternalPublish: Bool = false,
        screenshots: [ScreenshotUploadPayload] = [],
        attachments: [JobAttachment] = []
    ) async throws -> JobRequestResponse {
        if let error = JobAttachmentLimit.validate(attachments) {
            throw error
        }
        guard let url = URL(string: "jobs", relativeTo: baseURL) else {
            throw JobRequestError.invalidURL(path: "jobs")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: DaemonClient.tokenHeader)
        request.httpBody = try JSONEncoder().encode(
            JobRequestPayload(
                title: Self.resolveTitle(title: title, body: body),
                body: body,
                allowExternalPublish: allowExternalPublish,
                screenshots: screenshots,
                attachments: attachments
            )
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

    /// 部屋が対応している機能を引き、旧バックエンドでは未対応操作を出さない判断に使う。
    ///
    /// 旧バックエンドに `/capabilities` が無い（404 など）ときは `nil` を返す。
    /// 呼び出し側は `nil` を「未対応」とみなして添付 UI などを出さない。
    public func fetchCapabilities() async -> RoomCapabilities? {
        guard let url = URL(string: "capabilities", relativeTo: baseURL) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: DaemonClient.tokenHeader)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return nil
        }
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else {
            return nil
        }
        return try? JSONDecoder().decode(RoomCapabilities.self, from: data)
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
    /// スクショも添付も無いときは従来どおりの JSON のまま（既存互換）。
    private struct JobRequestPayload: Encodable {
        let title: String
        let body: String
        let source: String
        let allowExternalPublish: Bool
        let screenshots: [ScreenshotUploadPayload]
        let attachments: [AttachmentPayload]?

        init(
            title: String,
            body: String,
            allowExternalPublish: Bool = false,
            screenshots: [ScreenshotUploadPayload] = [],
            attachments: [JobAttachment] = []
        ) {
            self.title = title
            self.body = body
            self.source = "pet"
            self.allowExternalPublish = allowExternalPublish
            self.screenshots = screenshots
            self.attachments =
                attachments.isEmpty
                ? nil
                : attachments.map {
                    AttachmentPayload(name: $0.fileName, content: $0.data.base64EncodedString())
                }
        }

        enum CodingKeys: String, CodingKey {
            case title
            case body
            case source
            case allowExternalPublish = "allow_external_publish"
            case screenshots
            case attachments
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(title, forKey: .title)
            try container.encode(body, forKey: .body)
            try container.encode(source, forKey: .source)
            try container.encode(allowExternalPublish, forKey: .allowExternalPublish)
            if !screenshots.isEmpty {
                try container.encode(screenshots, forKey: .screenshots)
            }
            try container.encodeIfPresent(attachments, forKey: .attachments)
        }
    }

    /// 添付 1 件の JSON 表現。中身は base64 文字列。
    private struct AttachmentPayload: Encodable {
        let name: String
        let content: String
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

/// 依頼に同封する添付 1 件。名前と中身だけを持つ。
public struct JobAttachment: Sendable, Equatable {
    public let fileName: String
    public let data: Data

    public init(fileName: String, data: Data) {
        self.fileName = fileName
        self.data = data
    }

    /// 拡張子（小文字）。無ければ `nil`。
    public var fileExtension: String? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    /// バイト数。
    public var size: Int { data.count }
}

/// 添付の初期上限。部屋側の検証と揃える。
public enum JobAttachmentLimit {
    /// 添付の最大個数。
    public static let maxCount = 10
    /// 1 ファイルの最大バイト数（20MB）。
    public static let maxFileBytes = 20 * 1024 * 1024
    /// 依頼全体の添付合計の最大バイト数（50MB）。
    public static let maxTotalBytes = 50 * 1024 * 1024
    /// 受け付ける拡張子（小文字）。
    public static let allowedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "pdf", "md", "markdown", "txt",
    ]

    /// 拡張子が受け付けられるか。
    public static func isAllowedExtension(_ ext: String?) -> Bool {
        guard let ext else { return false }
        return allowedExtensions.contains(ext.lowercased())
    }

    /// 添付の集合を検証する。問題が無ければ `nil`、あれば最初の違反を返す。
    public static func validate(_ attachments: [JobAttachment]) -> JobAttachmentError? {
        if attachments.count > maxCount {
            return .tooManyFiles(maxCount)
        }
        var total = 0
        for attachment in attachments {
            if !isAllowedExtension(attachment.fileExtension) {
                return .rejectedExtension(attachment.fileName)
            }
            if attachment.size > maxFileBytes {
                return .fileTooLarge(attachment.fileName)
            }
            total += attachment.size
            if total > maxTotalBytes {
                return .totalTooLarge
            }
        }
        return nil
    }
}

/// 添付の検証で弾いた理由。送る前に呼び出し側へ返す。
public enum JobAttachmentError: Error, Equatable, Sendable, LocalizedError {
    /// 受け付けない形式のファイル。
    case rejectedExtension(String)
    /// 個数が上限を超えた。
    case tooManyFiles(Int)
    /// 1 ファイルが上限を超えた。
    case fileTooLarge(String)
    /// 合計が上限を超えた。
    case totalTooLarge

    public var errorDescription: String? {
        switch self {
        case .rejectedExtension(let name):
            return "\(name) は添付できない形式だよ（PNG・JPEG・PDF・Markdown・テキスト）"
        case .tooManyFiles(let limit):
            return "添付は \(limit) 個までだよ"
        case .fileTooLarge(let name):
            return "\(name) が 20MB を超えているよ"
        case .totalTooLarge:
            return "添付の合計が 50MB を超えているよ"
        }
    }
}

/// 部屋が対応している機能。`/capabilities` の応答。
///
/// 未知のフラグは false とみなし、旧バックエンドの応答にも落ちないようにする。
public struct RoomCapabilities: Decodable, Equatable, Sendable {
    public let attachmentUpload: Bool
    public let jobList: Bool
    public let jobHistory: Bool

    public init(
        attachmentUpload: Bool = false,
        jobList: Bool = false,
        jobHistory: Bool = false
    ) {
        self.attachmentUpload = attachmentUpload
        self.jobList = jobList
        self.jobHistory = jobHistory
    }

    enum CodingKeys: String, CodingKey {
        case attachmentUpload = "attachment_upload"
        case jobList = "job_list"
        case jobHistory = "job_history"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attachmentUpload = try container.decodeIfPresent(Bool.self, forKey: .attachmentUpload) ?? false
        jobList = try container.decodeIfPresent(Bool.self, forKey: .jobList) ?? false
        jobHistory = try container.decodeIfPresent(Bool.self, forKey: .jobHistory) ?? false
    }

    /// 添付が使えるか。
    public var supportsAttachments: Bool { attachmentUpload }
    /// 仕事一覧が使えるか。
    public var supportsJobList: Bool { jobList }
}
