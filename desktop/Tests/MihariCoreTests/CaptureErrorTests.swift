import Foundation
import Testing

@testable import MihariCore

@Suite("キャプチャ関連エラーの説明文")
struct CaptureErrorTests {

    private static let allCases: [CaptureError] = [
        .cameraPermissionNotGranted(detail: "denied (拒否)"),
        .cameraDeviceUnavailable,
        .cameraSessionConfigurationFailed(reason: "入力を追加できない"),
        .cameraPhotoDataMissing,
        .cameraCaptureFailed(reason: "内部エラー"),
        .screenRecordingPermissionNotGranted(detail: "false (未許可)"),
        .screenCaptureNoDisplay,
        .screenCaptureFailed(reason: "内部エラー"),
        .imageEncodingFailed,
        .imageDecodingFailed,
        .fileWriteFailed(reason: "ディスク容量不足"),
        .fileDeleteFailed(reason: "権限がない"),
    ]

    @Test("すべてのケースで説明文が空にならない")
    func allCasesHaveDescription() {
        for error in Self.allCases {
            #expect(!(error.errorDescription ?? "").isEmpty, "説明文が空: \(error)")
        }
    }

    @Test("カメラの権限エラーには渡した detail がそのまま含まれる")
    func cameraPermissionErrorEmbedsDetail() {
        let error = CaptureError.cameraPermissionNotGranted(detail: "denied (拒否)")
        #expect(error.errorDescription?.contains("denied (拒否)") == true)
    }

    @Test("画面収録の権限エラーには渡した detail がそのまま含まれる")
    func screenRecordingPermissionErrorEmbedsDetail() {
        let error = CaptureError.screenRecordingPermissionNotGranted(detail: "false (未許可)")
        #expect(error.errorDescription?.contains("false (未許可)") == true)
    }

    @Test("reason を持つエラーは reason の文言をそのまま含む")
    func reasonIsEmbedded() {
        #expect(CaptureError.cameraCaptureFailed(reason: "焦点が合わない").errorDescription?.contains("焦点が合わない") == true)
        #expect(CaptureError.fileWriteFailed(reason: "権限がない").errorDescription?.contains("権限がない") == true)
    }
}
