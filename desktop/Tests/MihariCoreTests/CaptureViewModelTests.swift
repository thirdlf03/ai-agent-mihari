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

@Suite("iPhone スクショの取得")
@MainActor
struct CaptureViewModelIPhoneTests {

    @Test("取得できたら iphone 種別の artifact として保存する")
    func savesIPhoneScreenshotAsArtifact() async {
        let model = CaptureViewModel(iphoneScreenshot: { Data([0x89, 0x50, 0x4E, 0x47]) })
        await model.captureIPhoneScreenshot()
        #expect(model.errorMessage == nil)
        #expect(model.lastArtifact?.kind == .iphone)
        if let url = model.lastArtifact?.url {
            #expect(FileManager.default.fileExists(atPath: url.path))
            try? model.lastArtifact?.delete()
        }
    }

    @Test("取得経路が無ければ(デーモン未接続)エラーを出すだけで落ちない")
    func missingProviderSetsError() async {
        let model = CaptureViewModel()
        await model.captureIPhoneScreenshot()
        #expect(model.lastArtifact == nil)
        #expect(model.errorMessage != nil)
    }

    @Test("取得に失敗したら理由を errorMessage に残す")
    func providerFailureSetsError() async {
        let model = CaptureViewModel(iphoneScreenshot: {
            throw DaemonError.requestFailed(status: 503, message: "tunneld に到達できない")
        })
        await model.captureIPhoneScreenshot()
        #expect(model.lastArtifact == nil)
        #expect(model.errorMessage?.contains("tunneld") == true)
    }
}
