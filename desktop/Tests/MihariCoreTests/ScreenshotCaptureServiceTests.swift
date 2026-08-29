import Foundation
import Testing

@testable import MihariCore

@Suite("スクリーンショット撮影サービス(権限まわり)")
struct ScreenshotCaptureServiceTests {

    @Test("権限が無ければ ScreenCaptureKit を呼ばず理由付きで失敗する")
    func missingPermissionFailsFast() async {
        await #expect(throws: CaptureError.screenRecordingPermissionNotGranted(detail: "false (未許可)")) {
            try await ScreenshotCaptureService.captureMainDisplayPNG(checkPermission: {
                PermissionState(grant: .undetermined, detail: "false (未許可)")
            })
        }
    }
}
