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

    @Test("権限が無ければ対象一覧も撮影も拒否する")
    func missingPermissionBlocksTargetsAndCapture() async {
        let denied: @Sendable () -> PermissionState = {
            PermissionState(grant: .denied, detail: "denied (拒否)")
        }
        await #expect(throws: CaptureError.screenRecordingPermissionNotGranted(detail: "denied (拒否)")) {
            try await ScreenshotCaptureService.availableTargets(checkPermission: denied)
        }
        await #expect(throws: CaptureError.screenRecordingPermissionNotGranted(detail: "denied (拒否)")) {
            let target = ScreenshotTarget(
                id: "display:1",
                kind: .display,
                title: "x",
                displayID: 1,
                pointWidth: 1512,
                pointHeight: 982,
                pixelWidth: 3024,
                pixelHeight: 1964,
                backingScale: 2.0,
                frameX: 0,
                frameY: 0
            )
            try await ScreenshotCaptureService.capturePNG(of: target, checkPermission: denied)
        }
    }
}

@Suite("スクショのメタデータ(Retina・複数画面)")
struct ScreenshotGeometryTests {

    @Test("Retina はピクセル÷ポイントの倍率 2.0 になる")
    func retinaScale() {
        let scale = ScreenshotCapture.measuredScale(
            pixelWidth: 3024,
            pointWidth: 1512,
            fallback: 1.0
        )
        #expect(scale == 2.0)
        let dims = ScreenshotTarget.pixelDimensions(
            pointWidth: 1512,
            pointHeight: 982,
            scale: 2.0
        )
        #expect(dims == (3024, 1964))
    }

    @Test("ポイント幅が 0 のときは実測から倍率を導けないので 1.0 に落とす")
    func unknownPointWidthFallsBack() {
        #expect(ScreenshotCapture.measuredScale(pixelWidth: 100, pointWidth: 0, fallback: 1.0) == 1.0)
    }

    @Test("複数画面は左側ディスプレイが負の座標を持つ")
    func multiDisplayNegativeOrigin() {
        // 左に置いた 2 台目: 論理 1920x1080 @2x。座標はポイントで負の側へ伸びる。
        let scale = 2.0
        let (px, _) = ScreenshotTarget.pixelCoordinate(pointX: -1920, pointY: 10, scale: scale)
        #expect(px == -3840)
        let rect = ScreenshotCaptureService.pixelRect(
            frameX: -1920,
            frameY: 0,
            pointWidth: 1920,
            pointHeight: 1080,
            scale: scale
        )
        #expect(rect.origin.x == -3840)
        #expect(rect.origin.y == 0)
        #expect(rect.width == 3840)
        #expect(rect.height == 2160)
    }
}
