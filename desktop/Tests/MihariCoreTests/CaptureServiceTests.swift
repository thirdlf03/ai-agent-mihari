import Foundation
import Testing

@testable import MihariCore

@Suite("CaptureService の窓口としての振る舞い")
struct CaptureServiceTests {

    @Test("カメラの権限が無ければ、そのまま理由付きで失敗が伝播する")
    func propagatesCameraPermissionError() async {
        let camera = CameraCaptureService(checkPermission: {
            PermissionState(grant: .denied, detail: "denied (拒否)")
        })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = CaptureService(camera: camera, temporaryDirectory: root)

        await #expect(throws: CaptureError.cameraPermissionNotGranted(detail: "denied (拒否)")) {
            _ = try await service.capturePhoto()
        }
    }
}
