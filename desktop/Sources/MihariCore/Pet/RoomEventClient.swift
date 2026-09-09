import Foundation

/// 部屋の SSE の 1 接続分のバイト列。
///
/// `URLSession.AsyncBytes` の違いを隠す包み。macOS 14 のデプロイ先でも `AsyncSequence` の
/// `Failure` を名前に出さずに box 化できる。
public struct RoomEventByteStream: AsyncSequence {
    public typealias Element = UInt8

    private let bytes: any AsyncSequence

    public struct AsyncIterator: AsyncIteratorProtocol {
        private var inner: any AsyncIteratorProtocol

        fileprivate init(_ inner: any AsyncIteratorProtocol) {
            self.inner = inner
        }

        public mutating func next() async throws -> Element? {
            guard let next = try await inner.next() else { return nil }
            return next as? UInt8
        }
    }

    public init<Base: AsyncSequence>(_ base: Base) {
        self.bytes = base
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(bytes.makeAsyncIterator())
    }
}

/// 部屋(REST + SSE)への口。`RoomJobMonitor` はこれを頼りに動く。
///
/// テストでは通信をスタブに差し替えられるように切り離してある。
public protocol RoomAccess: Sendable {
    /// `GET /jobs/running`。いま走っている仕事の詳細一覧。
    func listRunning() async throws -> [RoomJobDetail]
    /// `GET /jobs`。待ち・実行中・終端・Discord 作成を含む全仕事（履歴込み、新しい順）。
    func listJobs() async throws -> [RoomJobDetail]
    /// `GET /jobs/{id}`。仕事の詳細と成果物。
    func detail(jobID: String) async throws -> RoomJobDetail
    /// `POST /jobs/{id}/followup`。仕事へ追記する。
    func followup(jobID: String, body: String, requestedBy: String?) async throws -> JobRequestResponse
    /// `POST /jobs/{id}/steer`。実行中の仕事へ指示を足す（#40 想定）。
    func steer(jobID: String, instruction: String) async throws -> JobSteerResponse
    /// `POST /jobs/{id}/questions/{qid}/answer`。`waiting_for_input` への回答（#40 想定）。
    func answerQuestion(jobID: String, questionID: String, answer: String) async throws -> JobQuestionAnswerResponse
    /// `POST /jobs/{id}/cancel`。仕事を中断する。
    func cancel(jobID: String) async throws -> JobRequestResponse
    /// `GET /jobs/{id}/memory`。承認待ちを含む記憶の候補の一覧。
    func listMemory(jobID: String) async throws -> [RoomMemoryCandidate]
    /// `POST /jobs/{id}/memory/{candidateID}/approve`。承認する。
    func approveMemory(jobID: String, candidateID: String) async throws
    /// `POST /jobs/{id}/memory/{candidateID}/reject`。却下する。
    func rejectMemory(jobID: String, candidateID: String) async throws
    /// `POST /jobs/{id}/artifacts/{version}/rollback`。この版を再公開（新規の非公開バージョン）する。
    func rollbackArtifact(jobID: String, version: String) async throws -> RoomArtifact
    /// `POST /jobs/{id}/artifacts/{version}/publish`。版を公開し共有 URL を発行する。
    func publishArtifact(jobID: String, version: String) async throws -> RoomArtifact
    /// `POST /jobs/{id}/artifacts/{version}/unpublish`。版を非公開に戻し発行済み URL を無効化する。
    func unpublishArtifact(jobID: String, version: String) async throws -> RoomArtifact
    /// `POST /jobs/{id}/artifacts/{version}/restore`。その版の作業ファイルを作業フォルダへ復元する。
    func restoreArtifact(jobID: String, version: String) async throws
    /// `GET /jobs/{id}/events`。SSE をつなぎ、バイト列と HTTP 状態を返す。
    ///
    /// `lastEventID` が渡されたら `Last-Event-ID` ヘッダで再開点を伝える。
    /// SSE のバイト列は Sendable ではないので、作る側・読む側をメインアクタに閉じる。
    @MainActor
    func openEventStream(jobID: String, lastEventID: String?) async throws -> (RoomEventByteStream, Int)
}

/// 作業部屋 (room) の REST と SSE。
///
/// 認証は `JobRequestClient` と同じ `X-Mihari-Token` ヘッダを使う。トークンはヘッダにしか
/// 載せず、URL やログに出すことはない。SSE はデーモン(bridge)の購読とは別のセッションで
/// 開くので、そちらの流れを奪わない。
public struct RoomEventClient: Sendable, RoomAccess {

    /// VPS の部屋の URL を決める環境変数。
    public static let roomURLEnvironmentKey = JobRequestClient.roomURLEnvironmentKey
    /// VPS の部屋のトークンを決める環境変数。
    public static let roomTokenEnvironmentKey = JobRequestClient.roomTokenEnvironmentKey

    /// 接続先は `JobRequestClient` と同じ決め方。
    public static var defaultBaseURL: URL {
        JobRequestClient.defaultBaseURL
    }

    /// トークンも同じ決め方。未設定なら空文字。
    public static func defaultToken() -> String {
        JobRequestClient.defaultToken()
    }

    /// 環境変数から組み立てたクライアント。画面から使うときはこれでよい。
    public static func makeFromEnvironment(session: URLSession = .shared) -> RoomEventClient {
        RoomEventClient(baseURL: defaultBaseURL, token: defaultToken(), session: session)
    }

    private let baseURL: URL
    private let token: String
    private let session: URLSession
    private let streamingSession: URLSession

    public init(
        baseURL: URL,
        token: String,
        session: URLSession = .shared,
        streamingSession: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.streamingSession = streamingSession ?? Self.makeStreamingSession()
    }

    /// SSE 専用のセッション。デーモン側と同じくキャッシュを外し、無音で切らないようにする。
    public static func makeStreamingSession() -> URLSession {
        DaemonClient.makeStreamingSession()
    }

    /// 無音が続いても切らない秒数。
    static let streamIdleTimeout = DaemonClient.streamIdleTimeout

    // MARK: - RoomAccess

    public func listRunning() async throws -> [RoomJobDetail] {
        let response: RoomJobsResponse = try await get("jobs/running")
        return response.jobs
    }

    public func listJobs() async throws -> [RoomJobDetail] {
        let response: RoomJobsResponse = try await get("jobs")
        return response.jobs
    }

    public func detail(jobID: String) async throws -> RoomJobDetail {
        try await get("jobs/\(jobID)")
    }

    public func followup(
        jobID: String,
        body: String,
        requestedBy: String? = nil
    ) async throws -> JobRequestResponse {
        try await post(
            "jobs/\(jobID)/followup",
            body: RoomFollowupBody(body: body, requestedBy: requestedBy)
        )
    }

    /// 仕事へスクショ付きで追記する（#22）。
    public func followup(
        jobID: String,
        body: String,
        screenshots: [ScreenshotUploadPayload],
        requestedBy: String? = nil
    ) async throws -> JobRequestResponse {
        try await post(
            "jobs/\(jobID)/followup",
            body: RoomFollowupBody(
                body: body,
                requestedBy: requestedBy,
                screenshots: screenshots
            )
        )
    }

    public func cancel(jobID: String) async throws -> JobRequestResponse {
        try await post("jobs/\(jobID)/cancel", body: RoomCancelBody())
    }

    /// 実行中の仕事へ steer する。room #40 未デプロイ時は HTTP 404 等で失敗する。
    public func steer(jobID: String, instruction: String) async throws -> JobSteerResponse {
        try await post(
            "jobs/\(jobID)/steer",
            body: RoomSteerBody(instruction: instruction)
        )
    }

    /// `waiting_for_input` の質問へ回答する。room #40 未デプロイ時は HTTP 404 等で失敗する。
    public func answerQuestion(
        jobID: String,
        questionID: String,
        answer: String
    ) async throws -> JobQuestionAnswerResponse {
        try await post(
            "jobs/\(jobID)/questions/\(questionID)/answer",
            body: RoomQuestionAnswerBody(answer: answer)
        )
    }

    public func listMemory(jobID: String) async throws -> [RoomMemoryCandidate] {
        let response: RoomMemoryCandidatesResponse = try await get("jobs/\(jobID)/memory")
        return response.candidates
    }

    public func approveMemory(jobID: String, candidateID: String) async throws {
        let _: RoomMemoryDecisionAck = try await post(
            "jobs/\(jobID)/memory/\(candidateID)/approve",
            body: RoomEmptyBody()
        )
    }

    public func rejectMemory(jobID: String, candidateID: String) async throws {
        let _: RoomMemoryDecisionAck = try await post(
            "jobs/\(jobID)/memory/\(candidateID)/reject",
            body: RoomEmptyBody()
        )
    }

    public func rollbackArtifact(jobID: String, version: String) async throws -> RoomArtifact {
        try await post(
            "jobs/\(jobID)/artifacts/\(version)/rollback",
            body: RoomEmptyBody()
        )
    }

    /// 版を公開する。非公開へ戻してからの再公開は新しい共有 URL になる。
    public func publishArtifact(jobID: String, version: String) async throws -> RoomArtifact {
        try await post(
            "jobs/\(jobID)/artifacts/\(version)/publish",
            body: RoomEmptyBody()
        )
    }

    /// 版を非公開に戻す。その版の発行済み共有 URL は無効になる。
    public func unpublishArtifact(jobID: String, version: String) async throws -> RoomArtifact {
        try await post(
            "jobs/\(jobID)/artifacts/\(version)/unpublish",
            body: RoomEmptyBody()
        )
    }

    /// その版の作業ファイルを作業フォルダへ復元する（この版から修正の土台）。
    public func restoreArtifact(jobID: String, version: String) async throws {
        let _: RoomRestoreAck = try await post(
            "jobs/\(jobID)/artifacts/\(version)/restore",
            body: RoomEmptyBody()
        )
    }

    /// 非公開版の認証付きプレビュー用フェッチャー。トークンはヘッダだけに載せる。
    /// 中継先は `jobID` / `version` の files 配下に限る。
    public func previewFetcher(jobID: String, version: String) -> RoomPreviewFetcher {
        RoomPreviewFetcher(
            baseURL: baseURL,
            token: token,
            session: session,
            jobID: jobID,
            version: version
        )
    }

    /// SSE をつなぎ、バイト列と応答を返す。
    @MainActor
    public func openEventStream(
        jobID: String,
        lastEventID: String? = nil
    ) async throws -> (RoomEventByteStream, Int) {
        var request = try makeRequest(path: "jobs/\(jobID)/events")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let lastEventID, !lastEventID.isEmpty {
            request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
        }
        request.timeoutInterval = Self.streamIdleTimeout
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await streamingSession.bytes(for: request)
        } catch {
            throw RoomError.requestFailed(status: 0, message: error.localizedDescription)
        }
        return (RoomEventByteStream(bytes), (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    // MARK: - 共通の送受信

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(makeRequest(path: path))
    }

    private func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        var request = try makeRequest(path: path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func makeRequest(path: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            // トークンはヘッダなのでここには出ない。URL 文字列も丸ごとは出さない。
            throw RoomError.invalidURL(path: path)
        }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: DaemonClient.tokenHeader)
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RoomError.requestFailed(status: 0, message: error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw RoomError.requestFailed(status: status, message: Self.detail(from: data))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RoomError.requestFailed(
                status: status,
                message: "応答を解釈できない: \(error.localizedDescription)"
            )
        }
    }

    private static func detail(from data: Data) -> String {
        if let payload = try? JSONDecoder().decode(RoomErrorPayload.self, from: data) {
            return payload.detail
        }
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "詳細なし" : raw
    }

    /// `POST /jobs/{id}/followup` の本文。スクショが無いときは従来どおりの JSON。
    private struct RoomFollowupBody: Encodable {
        let body: String
        let requestedBy: String?
        let screenshots: [ScreenshotUploadPayload]

        init(
            body: String,
            requestedBy: String?,
            screenshots: [ScreenshotUploadPayload] = []
        ) {
            self.body = body
            self.requestedBy = requestedBy
            self.screenshots = screenshots
        }

        enum CodingKeys: String, CodingKey {
            case body
            case requestedBy = "requested_by"
            case screenshots
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(body, forKey: .body)
            try container.encodeIfPresent(requestedBy, forKey: .requestedBy)
            if !screenshots.isEmpty {
                try container.encode(screenshots, forKey: .screenshots)
            }
        }
    }

    /// `POST /jobs/{id}/cancel` の本文。中身は無いが、JSON の `{}` は送る。
    private struct RoomCancelBody: Encodable {}

    /// `POST /jobs/{id}/steer` の本文（room #47: `text` キー）。
    private struct RoomSteerBody: Encodable {
        let text: String

        init(instruction: String) {
            text = instruction
        }
    }

    /// `POST /jobs/{id}/questions/{qid}/answer` の本文（#40 想定）。
    private struct RoomQuestionAnswerBody: Encodable {
        let answer: String
    }

    /// 記憶の承認・却下の本文。部屋側は本文を要しないが、JSON の `{}` は送る。
    private struct RoomEmptyBody: Encodable {}

    /// 記憶の承認・却下の応答。部屋側の形が変わっても落とさないための入れ物。
    private struct RoomMemoryDecisionAck: Decodable {
        init(from decoder: Decoder) throws { _ = decoder }
    }

    /// 復元の応答。形は `{job_id, version, restored_files}`。中身は使わない。
    private struct RoomRestoreAck: Decodable {
        init(from decoder: Decoder) throws { _ = decoder }
    }

    /// 失敗の応答。本文の `detail` だけ読む。
    private struct RoomErrorPayload: Decodable {
        let detail: String
    }
}

/// 部屋の REST / SSE で起きる失敗。
public enum RoomError: Error, Equatable, Sendable {
    /// URL を組み立てられない。
    case invalidURL(path: String)
    /// 通信できない、部屋がエラーを返す、応答を読めない。
    case requestFailed(status: Int, message: String)
}

extension RoomError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL(let path):
            return "URL を組み立てられない: \(path)"
        case .requestFailed(let status, let message):
            return status == 0 ? message : "部屋がエラーを返した (\(status)): \(message)"
        }
    }
}
