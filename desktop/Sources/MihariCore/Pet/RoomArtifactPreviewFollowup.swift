import Foundation

/// プレビュー窓から送る「ここ直して」追記の本文を組み立てる。
/// プレビュー HTML 内（CSP で API 不可）ではなく desktop 側から followup する。
enum RoomPreviewFollowupBody {
    /// 短い指摘と、いま見ている版の目印を followup 本文に載せる。
    static func make(feedback: String, version: String) -> String {
        let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        ここ直して: \(trimmed)

        プレビュー中の版: v\(version)（アプリ内プレビュー）
        """
    }
}

/// プレビュー窓の「ここ直して」入力の状態。
@MainActor
public final class RoomArtifactPreviewViewModel: ObservableObject {
    /// 追記先の仕事 ID。
    public let jobID: String
    /// いまプレビューしている版。
    public let version: String
    /// 短い指摘テキスト。
    @Published public var feedback = ""
    @Published public private(set) var notice: String?
    @Published public private(set) var didFail = false
    @Published public private(set) var isSubmitting = false

    /// 入力の上限。プレビューからの短文指摘用。
    public static let maxFeedbackLength = 280

    private let sendFollowup: (String) async throws -> JobRequestResponse

    /// 本番用。部屋クライアント経由で followup する。
    public init(client: RoomEventClient, jobID: String, version: String) {
        self.jobID = jobID
        self.version = version
        self.sendFollowup = { body in
            try await client.followup(jobID: jobID, body: body)
        }
    }

    /// テスト用。followup の差し替え口。
    init(
        jobID: String,
        version: String,
        sendFollowup: @escaping (String) async throws -> JobRequestResponse
    ) {
        self.jobID = jobID
        self.version = version
        self.sendFollowup = sendFollowup
    }

    /// 空でなく、送信中でなく、長すぎなければ送れる。
    public var canSubmit: Bool {
        let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSubmitting else { return false }
        return trimmed.count <= Self.maxFeedbackLength
    }

    /// プレビュー中の版を目印に載せて followup する。
    public func submitFeedback() async {
        let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit else { return }
        isSubmitting = true
        notice = nil
        didFail = false
        defer { isSubmitting = false }
        let body = RoomPreviewFollowupBody.make(feedback: trimmed, version: version)
        do {
            _ = try await sendFollowup(body)
            feedback = ""
            notice = "ここ直して、送ったよ"
        } catch {
            didFail = true
            notice =
                (error as? LocalizedError)?.errorDescription
                ?? "送れなかったよ。もう一度試してみてね"
        }
    }
}
