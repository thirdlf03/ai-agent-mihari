import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import os

/// 撮影対象の種類。ディスプレイ全体か、1 つのウィンドウか（#22）。
public enum ScreenshotSourceKind: String, Sendable, Equatable, Codable {
    case display
    case window
}

/// 撮影対象（ディスプレイまたはウィンドウ）と、Retina・複数画面のためのメタデータ。
///
/// 座標は CoreGraphics のグローバル座標（ポイント、左上原点）で持つ。複数画面では
/// 左側のディスプレイが負の `frameX` を持つことがある。`backingScale` はピクセル÷
/// ポイントで、Retina は 2.0 になる。
public struct ScreenshotTarget: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: ScreenshotSourceKind
    public let title: String
    public let displayID: UInt32
    public let windowID: UInt32?
    /// 論理サイズ（ポイント）。
    public let pointWidth: Double
    public let pointHeight: Double
    /// 撮像素子サイズ（ピクセル）。
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// ピクセル÷ポイント。Retina は 2.0。
    public let backingScale: Double
    /// グローバル座標での左上の位置（ポイント）。
    public let frameX: Double
    public let frameY: Double

    public init(
        id: String,
        kind: ScreenshotSourceKind,
        title: String,
        displayID: UInt32,
        windowID: UInt32? = nil,
        pointWidth: Double,
        pointHeight: Double,
        pixelWidth: Int,
        pixelHeight: Int,
        backingScale: Double,
        frameX: Double,
        frameY: Double
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.displayID = displayID
        self.windowID = windowID
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.backingScale = backingScale
        self.frameX = frameX
        self.frameY = frameY
    }

    /// Retina などの倍率からピクセルサイズを求める。座標メタデータの自動テストに使う。
    public static func pixelDimensions(pointWidth: Double, pointHeight: Double, scale: Double) -> (
        width: Int, height: Int
    ) {
        (Int((pointWidth * scale).rounded()), Int((pointHeight * scale).rounded()))
    }

    /// ポイント座標をピクセル座標へ換算する。クリック操作（#23）の下準備。
    public static func pixelCoordinate(pointX: Double, pointY: Double, scale: Double) -> (x: Double, y: Double) {
        (pointX * scale, pointY * scale)
    }
}

/// 撮影結果 1 枚。`CGImage` は Sendable ではないため、撮影直後に PNG へ変換して
/// 渡す。メタデータは撮影の実測（画像ピクセルサイズ・フィルタの論理サイズ）から
/// 作るので、Retina や複数画面の倍率が実際の画像と食い違わない。
public struct ScreenshotCapture: Equatable, Sendable {
    public let pngData: Data
    public let kind: ScreenshotSourceKind
    public let title: String
    public let displayID: UInt32
    public let windowID: UInt32?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let pointWidth: Double
    public let pointHeight: Double
    public let backingScale: Double
    public let frameX: Double
    public let frameY: Double

    public init(
        pngData: Data,
        kind: ScreenshotSourceKind,
        title: String,
        displayID: UInt32,
        windowID: UInt32? = nil,
        pixelWidth: Int,
        pixelHeight: Int,
        pointWidth: Double,
        pointHeight: Double,
        backingScale: Double,
        frameX: Double,
        frameY: Double
    ) {
        self.pngData = pngData
        self.kind = kind
        self.title = title
        self.displayID = displayID
        self.windowID = windowID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.backingScale = backingScale
        self.frameX = frameX
        self.frameY = frameY
    }

    /// 実測値から倍率を計算する。ポイント幅が 0 ならフィルタ値を使う。
    public static func measuredScale(pixelWidth: Int, pointWidth: Double, fallback: Double) -> Double {
        guard pointWidth > 0 else { return fallback }
        return Double(pixelWidth) / pointWidth
    }
}

/// ScreenCaptureKit でディスプレイ・ウィンドウを選択して 1 枚キャプチャする。
///
/// `CGImage` は Sendable ではないため、非同期境界を越える前にこの型の中で
/// PNG データへ変換してしまい、呼び出し側には `Data` とメタデータだけを渡す。
public enum ScreenshotCaptureService {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "screenshot-capture")

    /// メインディスプレイを 1 枚キャプチャし、PNG データを返す。
    public static func captureMainDisplayPNG(
        checkPermission: @Sendable () -> PermissionState = { PermissionChecker.check(.screenRecording) }
    ) async throws -> Data {
        let permission = checkPermission()
        guard permission.grant == .granted else {
            throw CaptureError.screenRecordingPermissionNotGranted(detail: permission.detail)
        }

        let image = try await captureMainDisplayImage()
        return try CaptureImageCodec.pngData(from: image)
    }

    private static func captureMainDisplayImage() async throws -> CGImage {
        logger.info("SCShareableContent.current を取得する")
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw CaptureError.screenCaptureFailed(reason: error.localizedDescription)
        }

        let mainDisplayID = CGMainDisplayID()
        guard
            let display = content.displays.first(where: { $0.displayID == mainDisplayID })
                ?? content.displays.first
        else {
            throw CaptureError.screenCaptureNoDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = true
        configuration.captureResolution = .best

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            logger.info("キャプチャに成功した: \(image.width, privacy: .public)x\(image.height, privacy: .public)")
            return image
        } catch {
            throw CaptureError.screenCaptureFailed(reason: error.localizedDescription)
        }
    }

    /// 撮影できる対象（ディスプレイと前面のウィンドウ）を一覧で返す。
    ///
    /// ディスプレイは Retina/複数画面の実測（ピクセル・ポイント・座標・倍率）を
    /// 載せて返す。ウィンドウは中心が乗っているディスプレイの倍率を推定に使う。
    public static func availableTargets(
        checkPermission: @Sendable () -> PermissionState = { PermissionChecker.check(.screenRecording) }
    ) async throws -> [ScreenshotTarget] {
        let permission = checkPermission()
        guard permission.grant == .granted else {
            throw CaptureError.screenRecordingPermissionNotGranted(detail: permission.detail)
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw CaptureError.screenCaptureFailed(reason: error.localizedDescription)
        }
        let screens = NSScreen.screens

        var targets: [ScreenshotTarget] = []
        for display in content.displays {
            let displayID = display.displayID
            let pixelWidth = Int(CGDisplayPixelsWide(displayID))
            let pixelHeight = Int(CGDisplayPixelsHigh(displayID))
            let pointWidth = Double(display.width)
            let pointHeight = Double(display.height)
            let bounds = CGDisplayBounds(displayID)
            let name =
                screens.first {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                        == displayID
                }?.localizedName ?? "ディスプレイ"
            targets.append(
                ScreenshotTarget(
                    id: "display:\(displayID)",
                    kind: .display,
                    title: "\(name) (\(pixelWidth)×\(pixelHeight))",
                    displayID: displayID,
                    pointWidth: pointWidth,
                    pointHeight: pointHeight,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    backingScale: ScreenshotCapture.measuredScale(
                        pixelWidth: pixelWidth,
                        pointWidth: pointWidth,
                        fallback: 1.0
                    ),
                    frameX: bounds.origin.x,
                    frameY: bounds.origin.y
                )
            )
        }

        for window in content.windows where window.windowLayer == 0 && window.isOnScreen {
            let appName = window.owningApplication?.applicationName ?? "アプリ"
            let title = (window.title?.isEmpty == false) ? window.title! : "(無題)"
            let centerPoint = CGPoint(x: window.frame.midX, y: window.frame.midY)
            let containingID = Self.displayIDContaining(center: centerPoint, displays: content.displays)
            let scale = Self.scaleForDisplay(containingID ?? CGMainDisplayID(), displays: content.displays)
            let (pixelWidth, pixelHeight) = ScreenshotTarget.pixelDimensions(
                pointWidth: window.frame.width,
                pointHeight: window.frame.height,
                scale: scale
            )
            targets.append(
                ScreenshotTarget(
                    id: "window:\(window.windowID)",
                    kind: .window,
                    title: "\(appName): \(title)",
                    displayID: containingID ?? CGMainDisplayID(),
                    windowID: window.windowID,
                    pointWidth: window.frame.width,
                    pointHeight: window.frame.height,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    backingScale: scale,
                    frameX: window.frame.origin.x,
                    frameY: window.frame.origin.y
                )
            )
        }
        return targets
    }

    /// 指定対象を 1 枚撮って PNG とメタデータを返す。
    public static func capturePNG(
        of target: ScreenshotTarget,
        checkPermission: @Sendable () -> PermissionState = { PermissionChecker.check(.screenRecording) }
    ) async throws -> ScreenshotCapture {
        let permission = checkPermission()
        guard permission.grant == .granted else {
            throw CaptureError.screenRecordingPermissionNotGranted(detail: permission.detail)
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw CaptureError.screenCaptureFailed(reason: error.localizedDescription)
        }

        let image: CGImage
        let filter: SCContentFilter
        do {
            (image, filter) = try await captureImage(target: target, content: content)
        } catch {
            throw CaptureError.screenCaptureFailed(reason: error.localizedDescription)
        }

        let pngData = try CaptureImageCodec.pngData(from: image)
        let pointWidth = filter.contentRect.width
        let pointHeight = filter.contentRect.height
        let scale = ScreenshotCapture.measuredScale(
            pixelWidth: image.width,
            pointWidth: pointWidth,
            fallback: Double(filter.pointPixelScale)
        )
        logger.info("キャプチャに成功した: \(image.width, privacy: .public)x\(image.height, privacy: .public)")
        return ScreenshotCapture(
            pngData: pngData,
            kind: target.kind,
            title: target.title,
            displayID: target.displayID,
            windowID: target.windowID,
            pixelWidth: image.width,
            pixelHeight: image.height,
            pointWidth: pointWidth,
            pointHeight: pointHeight,
            backingScale: scale,
            frameX: target.frameX,
            frameY: target.frameY
        )
    }

    private static func captureImage(target: ScreenshotTarget, content: SCShareableContent) async throws -> (
        CGImage, SCContentFilter
    ) {
        let filter: SCContentFilter
        if target.kind == .display {
            guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
                throw CaptureError.screenCaptureNoDisplay
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else {
            guard let window = content.windows.first(where: { $0.windowID == target.windowID }) else {
                throw CaptureError.screenCaptureFailed(reason: "ウィンドウが見つからない（閉じられた可能性が高い）")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }
        let configuration = SCStreamConfiguration()
        let scale = filter.pointPixelScale > 0 ? Double(filter.pointPixelScale) : 1.0
        configuration.width = max(1, Int((filter.contentRect.width * scale).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * scale).rounded()))
        configuration.showsCursor = true
        configuration.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return (image, filter)
    }

    // MARK: - 座標・倍率のメタデータ（純粋関数。自動テストの対象）

    /// 中心点がどのディスプレイに乗っているかを返す。無ければ `nil`（呼び出し側が主ディスプレイに落とす）。
    static func displayIDContaining(center: CGPoint, displays: [SCDisplay]) -> UInt32? {
        for display in displays {
            if CGDisplayBounds(display.displayID).contains(center) {
                return display.displayID
            }
        }
        return nil
    }

    /// ディスプレイのピクセル÷ポイント倍率。不明なら 1.0。
    static func scaleForDisplay(_ displayID: UInt32, displays: [SCDisplay]) -> Double {
        guard let display = displays.first(where: { $0.displayID == displayID }) else { return 1.0 }
        let pointWidth = Double(display.width)
        guard pointWidth > 0 else { return 1.0 }
        return Double(CGDisplayPixelsWide(displayID)) / pointWidth
    }

    /// ポイント座標の原点をピクセルへ換算した「撮影領域」を返す。自動テストの対象。
    static func pixelRect(frameX: Double, frameY: Double, pointWidth: Double, pointHeight: Double, scale: Double)
        -> CGRect
    {
        let (x, y) = ScreenshotTarget.pixelCoordinate(pointX: frameX, pointY: frameY, scale: scale)
        let (w, h) = ScreenshotTarget.pixelDimensions(pointWidth: pointWidth, pointHeight: pointHeight, scale: scale)
        return CGRect(x: x, y: y, width: Double(w), height: Double(h))
    }
}
