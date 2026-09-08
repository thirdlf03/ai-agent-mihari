import Foundation
import Testing

@testable import MihariCore

/// プレビュー窓の「ここ直して」追記（desktop ネイティブ → POST /jobs/{id}/followup）。
@Suite("プレビューのここ直して追記")
@MainActor
struct RoomArtifactPreviewFollowupTests {

    @Test("followup 本文に版の目印を載せる")
    func followupBodyIncludesVersion() {
        let body = RoomPreviewFollowupBody.make(feedback: "色を濃く", version: "2")
        #expect(body.contains("ここ直して: 色を濃く"))
        #expect(body.contains("プレビュー中の版: v2（アプリ内プレビュー）"))
    }

    @Test("送ると followup を呼び、みはり口調で成功を知らせる")
    func submitSendsFollowupAndShowsSuccessNotice() async {
        var capturedBody: String?
        let model = RoomArtifactPreviewViewModel(
            jobID: "abc",
            version: "1",
            sendFollowup: { body in
                capturedBody = body
                return JobRequestResponse(jobID: "abc", threadID: nil, status: "queued")
            }
        )
        model.feedback = "ボタンを大きく"

        #expect(model.canSubmit == true)
        await model.submitFeedback()

        #expect(capturedBody?.contains("ここ直して: ボタンを大きく") == true)
        #expect(capturedBody?.contains("v1") == true)
        #expect(model.feedback.isEmpty)
        #expect(model.notice == "ここ直して、送ったよ")
        #expect(model.didFail == false)
    }

    @Test("空や空白だけでは送れない")
    func emptyFeedbackCannotSubmit() async {
        let model = RoomArtifactPreviewViewModel(
            jobID: "abc",
            version: "1",
            sendFollowup: { _ in
                Issue.record("followup は呼ばれない")
                return JobRequestResponse(jobID: "abc", threadID: nil, status: "queued")
            }
        )
        model.feedback = "   "
        #expect(model.canSubmit == false)
        await model.submitFeedback()
    }

    @Test("280 文字を超えたら送れない（trim 後）")
    func tooLongFeedbackCannotSubmit() async {
        let model = RoomArtifactPreviewViewModel(
            jobID: "abc",
            version: "1",
            sendFollowup: { _ in
                Issue.record("followup は呼ばれない")
                return JobRequestResponse(jobID: "abc", threadID: nil, status: "queued")
            }
        )
        model.feedback = String(repeating: "あ", count: 281)
        #expect(model.trimmedFeedbackCount == 281)
        #expect(model.isOverCharacterLimit == true)
        #expect(model.canSubmit == false)
    }

    @Test("前後空白は文字数に数えない")
    func paddingDoesNotCountTowardLimit() {
        let core = String(repeating: "あ", count: 280)
        let model = RoomArtifactPreviewViewModel(
            jobID: "abc",
            version: "1",
            sendFollowup: { _ in JobRequestResponse(jobID: "abc", threadID: nil, status: "queued") }
        )
        model.feedback = "  \(core)  "
        #expect(model.trimmedFeedbackCount == 280)
        #expect(model.isOverCharacterLimit == false)
        #expect(model.canSubmit == true)
    }

    @Test("trim 後 281 文字なら前後空白があっても送れない")
    func paddedTooLongFeedbackCannotSubmit() {
        let core = String(repeating: "あ", count: 281)
        let model = RoomArtifactPreviewViewModel(
            jobID: "abc",
            version: "1",
            sendFollowup: { _ in JobRequestResponse(jobID: "abc", threadID: nil, status: "queued") }
        )
        model.feedback = " \(core) "
        #expect(model.trimmedFeedbackCount == 281)
        #expect(model.isOverCharacterLimit == true)
        #expect(model.canSubmit == false)
    }

    @Test("失敗しても UI にはみはり口調だけ出す（LocalizedError も隠す）")
    func submitFailureShowsMihariNotice() async {
        struct SampleError: LocalizedError {
            var errorDescription: String? { "部屋が応答しなかった" }
        }
        let model = RoomArtifactPreviewViewModel(
            jobID: "abc",
            version: "1",
            sendFollowup: { _ in throw SampleError() }
        )
        model.feedback = "直して"
        await model.submitFeedback()

        #expect(model.didFail == true)
        #expect(model.notice == RoomArtifactPreviewViewModel.failureNotice)
        #expect(model.feedback == "直して")
    }

    @Test("RoomError も UI には出さずみはり口調に統一する")
    func submitRoomErrorUsesMihariNotice() async {
        let model = RoomArtifactPreviewViewModel(
            jobID: "abc",
            version: "1",
            sendFollowup: { _ in throw RoomError.requestFailed(status: 503, message: "続きを書いて") }
        )
        model.feedback = "直して"
        await model.submitFeedback()

        #expect(model.didFail == true)
        #expect(model.notice == RoomArtifactPreviewViewModel.failureNotice)
    }

    @Test("不明なエラーは汎用の失敗メッセージになる")
    func submitUnknownFailureUsesFallbackNotice() async {
        enum Boom: Error { case boom }
        let model = RoomArtifactPreviewViewModel(
            jobID: "abc",
            version: "1",
            sendFollowup: { _ in throw Boom.boom }
        )
        model.feedback = "直して"
        await model.submitFeedback()

        #expect(model.didFail == true)
        #expect(model.notice == RoomArtifactPreviewViewModel.failureNotice)
    }
}
