import Foundation

/// 依頼窓の下書き。本文・タイトル・添付・設定を 1 枚にまとめる。
///
/// 添付は元ファイルのパスを覚えておき、復元時に読み直す。送信前のプレビュー表示には
/// 窓を開いている間の `JobAttachment`（実データ）を別に持ち、ここには軽い情報だけを残す。
public struct JobRequestDraft: Codable, Equatable, Sendable {
    public var body: String
    public var title: String
    public var autoTitle: Bool
    public var attachments: [DraftAttachment]
    /// その他の設定（自動タイトルなど）。将来足す設定を壊さずに持ち回る入れ物。
    public var settings: [String: String]

    public init(
        body: String = "",
        title: String = "",
        autoTitle: Bool = true,
        attachments: [DraftAttachment] = [],
        settings: [String: String] = [:]
    ) {
        self.body = body
        self.title = title
        self.autoTitle = autoTitle
        self.attachments = attachments
        self.settings = settings
    }
}

/// 下書きに残す添付 1 件。中身は保存せず、元ファイルのパスで参照する。
public struct DraftAttachment: Codable, Equatable, Sendable {
    public var fileName: String
    public var storedPath: String
    public var size: Int
    public var fileExtension: String

    public init(fileName: String, storedPath: String, size: Int, fileExtension: String) {
        self.fileName = fileName
        self.storedPath = storedPath
        self.size = size
        self.fileExtension = fileExtension
    }
}

/// 下書きの保存・復元・削除の口。テストでは差し替えられるように切り離す。
public protocol JobRequestDraftStoring {
    func save(_ draft: JobRequestDraft) throws
    func load() throws -> JobRequestDraft?
    func clear()
}

/// 下書きを 1 つの JSON ファイルに置く実体。既定は Application Support 配下。
public struct DiskJobRequestDraftStore: JobRequestDraftStoring {

    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base =
            fileURL
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("Mihari", isDirectory: true)
        self.fileURL = base.appendingPathComponent("job-request-draft.json")
    }

    public func save(_ draft: JobRequestDraft) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(draft)
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    public func load() throws -> JobRequestDraft? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(JobRequestDraft.self, from: data)
    }

    public func clear() {
        try? fileManager.removeItem(at: fileURL)
    }
}
