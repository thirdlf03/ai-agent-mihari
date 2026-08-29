import Foundation
import Testing

@testable import MihariCore

@Suite("CaptureView の状態管理")
@MainActor
struct CaptureViewModelTests {

    @Test("初期状態では何も撮っておらず、エラーも無い")
    func startsEmpty() {
        let model = CaptureViewModel(service: CaptureService())
        #expect(model.lastArtifact == nil)
        #expect(model.previewImage == nil)
        #expect(model.errorMessage == nil)
        #expect(model.isCapturingPhoto == false)
        #expect(model.isCapturingScreenshot == false)
    }

    @Test("カメラの権限が無いときは落ちずに errorMessage へ理由が入る")
    func setsErrorMessageOnCameraPermissionFailure() async {
        let camera = CameraCaptureService(checkPermission: {
            PermissionState(grant: .denied, detail: "denied (拒否)")
        })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = CaptureViewModel(service: CaptureService(camera: camera, temporaryDirectory: root))

        await model.capturePhoto()

        #expect(model.errorMessage != nil)
        #expect(model.lastArtifact == nil)
        #expect(model.isCapturingPhoto == false)
    }

    @Test("撮影結果が無いときに削除しても何も起きない")
    func deletingWithNoArtifactIsNoop() {
        let model = CaptureViewModel(service: CaptureService())
        model.deleteLastArtifact()
        #expect(model.errorMessage == nil)
    }
}
