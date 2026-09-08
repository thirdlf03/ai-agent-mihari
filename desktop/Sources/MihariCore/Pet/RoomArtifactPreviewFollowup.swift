import Foundation
import os

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

    /// 入力の上限。プレビューからの短文指摘用（前後空白を除いた文字数）。
    public static let maxFeedbackLength = 280
    /// followup 失敗時に UI へ出すみはり口調の文言。
    static let failureNotice = "送れなかったよ。もう一度試してみてね"

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "room-preview")

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

    /// 前後空白を除いた入力。文字数制限・送信本文の基準。
    public var trimmedFeedback: String {
        feedback.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 制限判定に使う文字数（trim 後）。
    public var trimmedFeedbackCount: Int {
        trimmedFeedback.count
    }

    /// trim 後の文字数が上限を超えている。
    public var isOverCharacterLimit: Bool {
        trimmedFeedbackCount > Self.maxFeedbackLength
    }

    /// 空でなく、送信中でなく、trim 後が長すぎなければ送れる。
    public var canSubmit: Bool {
        guard !trimmedFeedback.isEmpty, !isSubmitting else { return false }
        return !isOverCharacterLimit
    }

    /// プレビュー中の版を目印に載せて followup する。
    public func submitFeedback() async {
        let trimmed = trimmedFeedback
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
            notice = Self.failureNotice
            Self.logger.error(
                "プレビューからの followup に失敗 job=\(self.jobID, privacy: .public) version=\(self.version, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }
}
