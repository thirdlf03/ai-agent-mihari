import AppKit
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
            _ = try await ScreenshotCaptureService.capturePNG(of: target, checkPermission: denied)
        }
        await #expect(throws: CaptureError.screenRecordingPermissionNotGranted(detail: "denied (拒否)")) {
            _ = try await SystemScreenshotPicker.pick(checkPermission: denied)
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

@Suite("システムの対象選びから画面・ウィンドウを当てる")
struct ScreenshotSourceResolveTests {

    private let builtIn = ScreenshotCaptureService.DisplaySnapshot(
        displayID: 1,
        bounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
        title: "Built-in (3024×1964)"
    )
    private let left = ScreenshotCaptureService.DisplaySnapshot(
        displayID: 2,
        bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        title: "左の画面 (3840×2160)"
    )
    private let safari = ScreenshotCaptureService.WindowSnapshot(
        windowID: 42,
        frame: CGRect(x: 100, y: 80, width: 800, height: 600),
        title: "Safari: 検索"
    )

    @Test("ウィンドウ枠がほぼ同じならウィンドウとして当てる")
    func matchesWindowByFrame() {
        let source = ScreenshotCaptureService.resolveSource(
            styleHint: .window,
            contentRect: CGRect(x: 102, y: 78, width: 800, height: 600),
            displays: [builtIn],
            windows: [safari]
        )
        #expect(source.kind == .window)
        #expect(source.windowID == 42)
        #expect(source.displayID == 1)
        #expect(source.title == "Safari: 検索")
    }

    @Test("画面全体を選んだときはウィンドウがあっても画面として当てる")
    func displayHintIgnoresOverlappingWindow() {
        let fullscreenWindow = ScreenshotCaptureService.WindowSnapshot(
            windowID: 9,
            frame: builtIn.bounds,
            title: "アプリ: 全画面"
        )
        let source = ScreenshotCaptureService.resolveSource(
            styleHint: .display,
            contentRect: builtIn.bounds,
            displays: [builtIn, left],
            windows: [fullscreenWindow]
        )
        #expect(source.kind == .display)
        #expect(source.displayID == 1)
        #expect(source.windowID == nil)
        #expect(source.title == "Built-in (3024×1964)")
    }

    @Test("左側の画面は負の座標のまま当てる")
    func matchesLeftDisplayNegativeOrigin() {
        let source = ScreenshotCaptureService.resolveSource(
            styleHint: .display,
            contentRect: left.bounds,
            displays: [builtIn, left],
            windows: []
        )
        #expect(source.kind == .display)
        #expect(source.displayID == 2)
        #expect(source.frameX == -1920)
        #expect(source.title == "左の画面 (3840×2160)")
    }

    @Test("ヒントが無くても重なりが大きいウィンドウを当てる")
    func infersWindowFromOverlap() {
        let source = ScreenshotCaptureService.resolveSource(
            styleHint: nil,
            contentRect: CGRect(x: 120, y: 100, width: 760, height: 560),
            displays: [builtIn],
            windows: [safari]
        )
        #expect(source.kind == .window)
        #expect(source.windowID == 42)
    }
}

@Suite("対象選び中の依頼窓の前面維持")
@MainActor
struct ScreenshotPickerAnchorTests {

    @Test("選んでいるあいだは浮かべ、終わったら元の階層へ戻す")
    func holdsFloatingThenRestoresLevel() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.level = .normal
        window.hidesOnDeactivate = true

        let anchor = ScreenshotPickerAnchor(window: window)
        #expect(anchor != nil)
        #expect(window.level == .floating)
        #expect(window.hidesOnDeactivate == false)

        anchor?.restore()
        #expect(window.level == .normal)
        #expect(window.hidesOnDeactivate == true)
    }

    @Test("窓が無ければ何もしない")
    func missingWindowIsIgnored() {
        #expect(ScreenshotPickerAnchor(window: nil) == nil)
    }
}
