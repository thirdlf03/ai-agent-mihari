import Foundation

/// 部屋の仕事の進捗位相。
///
/// SSE `/jobs/{id}/events` の `phase` に入る値。部屋が将来足す未知の位相は
/// `init(rawValue:)` が失敗して `nil` になり、黙って無視される。
public enum RoomJobPhase: String, Sendable, Equatable, CaseIterable {
    case queued
    case researching
    case downloading
    case building
    case deploying
    case verifying
    case waiting
    case done
    case failed

    /// 画面表示用の日本語ラベル。
    public var label: String {
        switch self {
        case .queued: return "待ち"
        case .researching: return "調査中"
        case .downloading: return "取得中"
        case .building: return "組み立て中"
        case .deploying: return "配置中"
        case .verifying: return "確認中"
        case .waiting: return "待ち"
        case .done: return "完了"
        case .failed: return "失敗"
        }
    }

    /// 位相をペットの固着アニメーションへ写す。
    ///
    /// done は「1 回だけのお祝い」に任せるため固定は返さない。failed は落ち込んだ姿で固定する。
    public var fixedAnimation: PetAnimation? {
        switch self {
        case .queued, .waiting: return .waiting
        case .researching, .downloading, .deploying: return .running
        case .building, .verifying: return .review
        case .done: return nil
        case .failed: return .failed
        }
    }

    /// 終わった位相か。summary / 祝いのきっかけに使う。
    public var isTerminal: Bool {
        self == .done || self == .failed
    }
}

/// SSE イベントの種類。`cancelled` は部屋が中断を流すときに使う(位相は `waiting`)。
///
/// 未知の種類は `init(rawValue:)` が失敗して `nil` になる。
public enum RoomEventKind: String, Sendable, Equatable, CaseIterable {
    case speech
    case log
    case summary
    case file
    case cancelled
    /// 記憶の候補が出た。位相は waiting。喋らず、記憶の一覧を引き直す合図。
    case memoryCandidate = "memory_candidate"
    /// 一時デプロイできた。位相は deploying。claim URL は本文に出ない。
    case tempDeploy = "temp_deploy"
}

/// 詳細パネルの「履歴」に出す 1 件。監視中に流れたイベントの要約。
public struct RoomJobHistoryEntry: Equatable, Sendable {
    public let phase: RoomJobPhase?
    public let kind: RoomEventKind?
    public let text: String

    public init(phase: RoomJobPhase?, kind: RoomEventKind?, text: String) {
        self.phase = phase
        self.kind = kind
        self.text = text
    }
}

/// ペットに渡す位相の変化。
///
/// 位相を写した固着アニメーションと、1 回だけ挟むアニメーション、吹き出しのセリフ。
/// `LivePetPresenter.PetDirective` と同じ形だが、検知とは無関係に作る。
public struct RoomPhaseDirective: Equatable, Sendable {
    /// 固定するアニメーション。nil なら自律行動に戻す。
    public let fixedAnimation: PetAnimation?
    /// 1 回だけ挟むアニメーション。
    public let playOnce: PetAnimation?
    /// 吹き出しに出すセリフ。nil なら出さない。
    public let line: String?

    public init(
        fixedAnimation: PetAnimation? = nil,
        playOnce: PetAnimation? = nil,
        line: String? = nil
    ) {
        self.fixedAnimation = fixedAnimation
        self.playOnce = playOnce
        self.line = line
    }
}

/// `/jobs/{id}/events` の SSE から届く 1 件のイベント。
///
/// 全部を任意にしたうえで未知のフィールドは黙って無視し、部屋の実装が多少変わっても
/// 落ちないようにしてある。`id` は重複排除と Last-Event-ID の再開点に使う。
public struct RoomEvent: Decodable, Equatable, Sendable, Identifiable {
    /// イベントの一意な ID。未設定・読めないときは本文と時刻から合成する。
    public let id: String
    /// どの仕事のイベントか。
    public let jobID: String
    /// 進捗位相。未知の値は `nil`(位相の変化としては扱わない)。
    public let phase: RoomJobPhase?
    /// イベントの種類。未知の値は `nil`。
    public let kind: RoomEventKind?
    /// 本文。
    public let text: String
    /// 0〜100 の進捗。付いていなければ `nil`。
    public let progress: Double?
    /// 発生時刻。解釈できなければ `nil`。
    public let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case jobID = "job_id"
        case phase
        case kind
        case text
        case progress
        case createdAt = "created_at"
    }

    public init(
        id: String,
        jobID: String,
        phase: RoomJobPhase?,
        kind: RoomEventKind?,
        text: String,
        progress: Double? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.jobID = jobID
        self.phase = phase
        self.kind = kind
        self.text = text
        self.progress = progress
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        let rawID = Self.decodeFlexibleID(container)
        let createdAtRaw = try container.decodeIfPresent(String.self, forKey: .createdAt)
        let createdAt = createdAtRaw.flatMap(DaemonEvent.parseTimestamp)
        // id が無くても重複排除の目印が欲しいので、本文と時刻から合成する。
        id = rawID ?? Self.synthesizedID(text: text, createdAt: createdAt)
        jobID = try container.decodeIfPresent(String.self, forKey: .jobID) ?? ""
        phase = (try container.decodeIfPresent(String.self, forKey: .phase)).flatMap(RoomJobPhase.init)
        kind = (try container.decodeIfPresent(String.self, forKey: .kind)).flatMap(RoomEventKind.init)
        self.text = text
        progress = try container.decodeIfPresent(Double.self, forKey: .progress)
        self.createdAt = createdAt
    }

    /// `id` を文字列でも数値でも読む。部屋の日誌は数値、SSE の `id:` 行は文字列。
    ///
    /// 数値はそのまま文字列化するので、カーソル(`Last-Event-ID`)も数値文字列で
    /// 往復する。部屋側は数値以外を 0(最初から)とみなす。
    static func decodeFlexibleID(_ container: KeyedDecodingContainer<CodingKeys>) -> String? {
        if let string = try? container.decodeIfPresent(String.self, forKey: .id) {
            return string
        }
        if let number = try? container.decodeIfPresent(Int.self, forKey: .id) {
            return String(number)
        }
        if let number = try? container.decodeIfPresent(Double.self, forKey: .id) {
            return String(Int(number))
        }
        return nil
    }

    /// `id` が付いていないときの代替。同じ本文・同じ時刻は同じ ID に見えるようにする。
    private static func synthesizedID(text: String, createdAt: Date?) -> String {
        let stamp = createdAt?.timeIntervalSince1970.description ?? "unknown"
        return "\(stamp)-\(text.hashValue)"
    }
}

/// `/jobs/{id}` の成果物。`preview_url` が開ける URL なら「開く」操作に使う。
///
/// 版ごとに公開状態を持つ（新規は非公開）。
/// - 公開中: ``preview_url`` が共有 URL。ブラウザで開ける。
/// - 非公開: ``preview_url`` は無く、``view_path``（認証付き取得の相対経路）だけがある。
///   トークンは URL に載らず、desktop がヘッダで渡す。
public struct RoomArtifact: Decodable, Equatable, Sendable, Identifiable {
    public let artifactID: String
    public let jobID: String?
    public let sessionID: String?
    public let version: String?
    public let kind: String?
    public let previewURL: URL?
    /// 公開状態（"public" / "private"）。無い古い応答は preview_url の有無で判定する。
    public let visibility: String?
    /// 認証付き取得の相対経路。例: "/jobs/<id>/artifacts/3/files/"。URL にトークンは無い。
    public let viewPath: String?
    public let expiresAt: Date?
    public let sha256: String?
    public let sourceIDs: [String]

    public var id: String {
        if let version, !version.isEmpty {
            return "\(artifactID)-v\(version)"
        }
        return artifactID
    }

    /// 外部に公開されている版か。古い部屋（公開状態の無い応答）は共有 URL の有無で見る。
    public var isPublic: Bool {
        if let visibility {
            return visibility.lowercased() == "public"
        }
        return previewURL != nil
    }

    enum CodingKeys: String, CodingKey {
        case artifactID = "id"
        case jobID = "job_id"
        case sessionID = "session_id"
        case version
        case kind
        case previewURL = "preview_url"
        case visibility
        case viewPath = "view_url"
        case expiresAt = "expires_at"
        case sha256
        case sourceIDs = "source_ids"
    }

    public init(
        artifactID: String,
        jobID: String? = nil,
        sessionID: String? = nil,
        version: String? = nil,
        kind: String? = nil,
        previewURL: URL? = nil,
        visibility: String? = nil,
        viewPath: String? = nil,
        expiresAt: Date? = nil,
        sha256: String? = nil,
        sourceIDs: [String] = []
    ) {
        self.artifactID = artifactID
        self.jobID = jobID
        self.sessionID = sessionID
        self.version = version
        self.kind = kind
        self.previewURL = previewURL
        self.visibility = visibility
        self.viewPath = viewPath
        self.expiresAt = expiresAt
        self.sha256 = sha256
        self.sourceIDs = sourceIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        artifactID = try container.decodeIfPresent(String.self, forKey: .artifactID) ?? ""
        jobID = try container.decodeIfPresent(String.self, forKey: .jobID)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        version = try Self.decodeLossyString(container, key: .version)
        kind = try Self.decodeLossyString(container, key: .kind)
        previewURL = try Self.decodeURL(container, key: .previewURL)
        visibility = try container.decodeIfPresent(String.self, forKey: .visibility)
        viewPath = try container.decodeIfPresent(String.self, forKey: .viewPath)
        expiresAt = (try container.decodeIfPresent(String.self, forKey: .expiresAt)).flatMap(
            DaemonEvent.parseTimestamp
        )
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        sourceIDs = try container.decodeIfPresent([String].self, forKey: .sourceIDs) ?? []
    }

    /// 文字列でも数値でも同じに見える。`version` に使う。
    private static func decodeLossyString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> String? {
        if let string = try? container.decodeIfPresent(String.self, forKey: key) {
            return string
        }
        if let number = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(number)
        }
        return nil
    }

    /// `preview_url` を URL として読む。壊れた文字列は `nil`。
    private static func decodeURL(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> URL? {
        guard let raw = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return URL(string: raw)
    }
}

/// `/jobs/{id}` の一時デプロイ。`claim_url` は認証済み詳細だけに載る bearer。
public struct RoomTempDeploy: Decodable, Equatable, Sendable, Identifiable {
    public let previewURL: URL?
    public let claimURL: URL?
    public let expiresAt: Date?
    public let createdAt: Date?

    public var id: String {
        let preview = previewURL?.absoluteString ?? ""
        let stamp = createdAt?.timeIntervalSince1970.description ?? ""
        return "\(preview)-\(stamp)"
    }

    enum CodingKeys: String, CodingKey {
        case previewURL = "preview_url"
        case claimURL = "claim_url"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }

    public init(
        previewURL: URL? = nil,
        claimURL: URL? = nil,
        expiresAt: Date? = nil,
        createdAt: Date? = nil
    ) {
        self.previewURL = previewURL
        self.claimURL = claimURL
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        previewURL = try Self.decodeURL(container, key: .previewURL)
        claimURL = try Self.decodeURL(container, key: .claimURL)
        expiresAt = Self.decodeFlexibleDate(container, key: .expiresAt)
        createdAt = Self.decodeFlexibleDate(container, key: .createdAt)
    }

    private static func decodeURL(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> URL? {
        guard let raw = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return URL(string: raw)
    }

    private static func decodeFlexibleDate(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Date? {
        if let epoch = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: epoch)
        }
        if let raw = try? container.decodeIfPresent(String.self, forKey: key) {
            if let epoch = Double(raw) { return Date(timeIntervalSince1970: epoch) }
            return DaemonEvent.parseTimestamp(raw)
        }
        return nil
    }
}

/// `/jobs/running` と `/jobs/{id}` が返す仕事の詳細。
///
/// 全部を任意にして、部屋が将来足すフィールドを黙って無視する。
public struct RoomJobDetail: Decodable, Equatable, Sendable, Identifiable {
    public let jobID: String
    public let title: String?
    public let status: String?
    public let source: String?
    public let threadID: Int?
    public let sessionID: String?
    public let artifacts: [RoomArtifact]
    public let tempDeploys: [RoomTempDeploy]
    public let latestEvent: RoomEvent?
    /// 出生時刻（秒）。一覧の並びに使う。旧バックエンドでは `nil`。
    public let createdAt: Date?
    /// 依頼本文。一覧の検索に使う。旧バックエンドでは `nil`。
    public let body: String?

    public var id: String { jobID }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case title
        case status
        case source
        case threadID = "thread_id"
        case sessionID = "session_id"
        case artifacts
        case tempDeploys = "temp_deploys"
        case latestEvent = "latest_event"
        case createdAt = "created_at"
        case body
    }

    public init(
        jobID: String,
        title: String? = nil,
        status: String? = nil,
        source: String? = nil,
        threadID: Int? = nil,
        sessionID: String? = nil,
        artifacts: [RoomArtifact] = [],
        tempDeploys: [RoomTempDeploy] = [],
        latestEvent: RoomEvent? = nil,
        createdAt: Date? = nil,
        body: String? = nil
    ) {
        self.jobID = jobID
        self.title = title
        self.status = status
        self.source = source
        self.threadID = threadID
        self.sessionID = sessionID
        self.artifacts = artifacts
        self.tempDeploys = tempDeploys
        self.latestEvent = latestEvent
        self.createdAt = createdAt
        self.body = body
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try container.decodeIfPresent(String.self, forKey: .jobID) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        threadID = try container.decodeIfPresent(Int.self, forKey: .threadID)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        artifacts = try container.decodeIfPresent([RoomArtifact].self, forKey: .artifacts) ?? []
        tempDeploys =
            try container.decodeIfPresent([RoomTempDeploy].self, forKey: .tempDeploys) ?? []
        latestEvent = try container.decodeIfPresent(RoomEvent.self, forKey: .latestEvent)
        if let raw = try container.decodeIfPresent(Double.self, forKey: .createdAt) {
            createdAt = Date(timeIntervalSince1970: raw)
        } else if let raw = try container.decodeIfPresent(Int.self, forKey: .createdAt) {
            createdAt = Date(timeIntervalSince1970: Double(raw))
        } else {
            createdAt = nil
        }
        body = try container.decodeIfPresent(String.self, forKey: .body)
    }
}

/// `GET /jobs/running` の応答。
public struct RoomJobsResponse: Decodable, Equatable, Sendable {
    public let jobs: [RoomJobDetail]

    public init(jobs: [RoomJobDetail] = []) {
        self.jobs = jobs
    }
}

/// 承認待ちの記憶の候補。`GET /jobs/{id}/memory` の `candidates` の 1 件。
///
/// 部屋側の正本は `jobs/<id>/memory_candidates.json`。`target` は `MEMORY.md` /
/// `USER.md`、`status` は `pending` / `approved` / `rejected`。`created_at` は
/// 時刻(秒)でも ISO8601 文字列でも読む。承認・却下は API が成功してから一覧を
/// 引き直すまで約束しない。
public struct RoomMemoryCandidate: Decodable, Equatable, Sendable, Identifiable {
    public let candidateID: String
    public let target: String
    public let content: String
    public let status: String
    public let createdAt: Date?

    public var id: String { candidateID }
    /// まだ決めていない候補か。
    public var isPending: Bool { status.lowercased() == "pending" }

    enum CodingKeys: String, CodingKey {
        case candidateID = "id"
        case target
        case content
        case status
        case createdAt = "created_at"
    }

    public init(
        candidateID: String,
        target: String = "",
        content: String = "",
        status: String = "pending",
        createdAt: Date? = nil
    ) {
        self.candidateID = candidateID
        self.target = target
        self.content = content
        self.status = status
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        candidateID = Self.decodeFlexibleID(container) ?? ""
        target = (try? container.decodeIfPresent(String.self, forKey: .target)) ?? ""
        content = (try? container.decodeIfPresent(String.self, forKey: .content)) ?? ""
        status = (try? container.decodeIfPresent(String.self, forKey: .status)) ?? "pending"
        createdAt = Self.decodeFlexibleDate(container)
    }

    static func decodeFlexibleID(_ container: KeyedDecodingContainer<CodingKeys>) -> String? {
        if let string = try? container.decodeIfPresent(String.self, forKey: .candidateID) {
            return string
        }
        if let number = try? container.decodeIfPresent(Int.self, forKey: .candidateID) {
            return String(number)
        }
        return nil
    }

    static func decodeFlexibleDate(_ container: KeyedDecodingContainer<CodingKeys>) -> Date? {
        if let epoch = try? container.decodeIfPresent(Double.self, forKey: .createdAt) {
            return Date(timeIntervalSince1970: epoch)
        }
        if let epoch = try? container.decodeIfPresent(Int.self, forKey: .createdAt) {
            return Date(timeIntervalSince1970: Double(epoch))
        }
        if let raw = try? container.decodeIfPresent(String.self, forKey: .createdAt) {
            if let epoch = Double(raw) { return Date(timeIntervalSince1970: epoch) }
            return DaemonEvent.parseTimestamp(raw)
        }
        return nil
    }
}

/// `GET /jobs/{id}/memory` の応答。`{candidates:[...]}`。
public struct RoomMemoryCandidatesResponse: Decodable, Equatable, Sendable {
    public let candidates: [RoomMemoryCandidate]

    public init(candidates: [RoomMemoryCandidate] = []) {
        self.candidates = candidates
    }
}

/// ペットメニューに出す仕事の要約。
public struct RoomJobSummary: Equatable, Sendable {
    public let jobID: String
    public let title: String
    public let status: RoomJobStatus
    /// 最後に見た位相。未知のままだと `nil`。
    public let phase: RoomJobPhase?
    /// 最後のイベント本文。無ければ `nil`。
    public let latestText: String?
    /// 直近で取れた成果物。
    public let artifacts: [RoomArtifact]
    /// 一時デプロイ（workers.dev）。claim は詳細パネル。
    public let tempDeploys: [RoomTempDeploy]
    /// 配信が止まっている理由。正常なら `nil`。
    public let lastError: String?
    /// 直近の中断・承認・公開などの操作の失敗。正常なら `nil`。
    public let operationError: String?
    /// 直近で取れた記憶の候補。承認待ちの表示と件数に使う。
    public let memoryCandidates: [RoomMemoryCandidate]
    /// 承認待ちの件数。
    public var pendingMemoryCount: Int { memoryCandidates.filter(\.isPending).count }

    public init(
        jobID: String,
        title: String,
        status: RoomJobStatus,
        phase: RoomJobPhase? = nil,
        latestText: String? = nil,
        artifacts: [RoomArtifact] = [],
        tempDeploys: [RoomTempDeploy] = [],
        lastError: String? = nil,
        operationError: String? = nil,
        memoryCandidates: [RoomMemoryCandidate] = []
    ) {
        self.jobID = jobID
        self.title = title
        self.status = status
        self.phase = phase
        self.latestText = latestText
        self.artifacts = artifacts
        self.tempDeploys = tempDeploys
        self.lastError = lastError
        self.operationError = operationError
        self.memoryCandidates = memoryCandidates
    }
}
