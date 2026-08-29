import Foundation
import Testing

@testable import MihariCore

@Suite("カメラ撮影サービス(権限まわり)")
struct CameraCaptureServiceTests {

    @Test("権限が拒否されていれば AVCaptureSession に触れず理由付きで失敗する")
    func deniedPermissionFailsFast() async {
        let service = CameraCaptureService(checkPermission: {
            PermissionState(grant: .denied, detail: "denied (拒否)")
        })

        await #expect(throws: CaptureError.cameraPermissionNotGranted(detail: "denied (拒否)")) {
            _ = try await service.captureSinglePhoto()
        }
    }

    @Test("権限が未決定でも理由付きで失敗する(まだ聞いていないだけでは撮らない)")
    func undeterminedPermissionFailsFast() async {
        let service = CameraCaptureService(checkPermission: {
            PermissionState(grant: .undetermined, detail: "notDetermined (未決定)")
        })

        await #expect(throws: CaptureError.cameraPermissionNotGranted(detail: "notDetermined (未決定)")) {
            _ = try await service.captureSinglePhoto()
        }
    }
}
