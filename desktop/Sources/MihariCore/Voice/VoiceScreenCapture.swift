import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// マウス位置の取得口。テストでは固定座標に差し替える。
public protocol MouseLocationProviding: Sendable {
    func globalMouseLocation() -> CGPoint
}

/// `CGEvent` からグローバル座標（左上原点）を読む。
public struct CGEventMouseLocationProvider: MouseLocationProviding {
    public init() {}

    public func globalMouseLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}

/// ディスプレイ一覧の取得口。テストでは固定 bounds に差し替える。
public protocol DisplayBoundsListing: Sendable {
    func displayBounds() -> [MouseDisplayBounds]
}

/// 1 枚のディスプレイの bounds（CoreGraphics グローバル座標）。
public struct MouseDisplayBounds: Equatable, Sendable {
    public let displayID: UInt32
    public let bounds: CGRect
    public let title: String

    public init(displayID: UInt32, bounds: CGRect, title: String) {
        self.displayID = displayID
        self.bounds = bounds
        self.title = title
    }
}

/// 画面収録権限の確認口。
public protocol ScreenRecordingPermissionChecking: Sendable {
    func screenRecordingPermission() -> PermissionState
}

public struct LiveScreenRecordingPermissionChecker: ScreenRecordingPermissionChecking {
    public init() {}

    public func screenRecordingPermission() -> PermissionState {
        PermissionChecker.check(.screenRecording)
    }
}

/// 指定対象の PNG キャプチャ口。
public protocol DisplayPNGCapturing: Sendable {
    func captureDisplayPNG(displayID: UInt32, title: String) async throws -> Data
}

/// `ScreenshotCaptureService` 経由でディスプレイ 1 枚を撮る。
public struct LiveDisplayPNGCapture: DisplayPNGCapturing {
    private let checkPermission: @Sendable () -> PermissionState

    public init(
        checkPermission: @escaping @Sendable () -> PermissionState = {
            PermissionChecker.check(.screenRecording)
        }
    ) {
        self.checkPermission = checkPermission
    }

    public func captureDisplayPNG(displayID: UInt32, title: String) async throws -> Data {
        let targets = try await ScreenshotCaptureService.availableTargets(
            checkPermission: checkPermission
        )
        guard let target = targets.first(where: { $0.kind == .display && $0.displayID == displayID }) else {
            throw CaptureError.screenCaptureNoDisplay
        }
        return try await ScreenshotCaptureService.capturePNG(
            of: target,
            checkPermission: checkPermission
        ).pngData
    }
}

/// マウスがあるディスプレイを選ぶ純粋ロジック。
public enum MouseDisplaySelector {
    /// 点を含むディスプレイ ID。無ければ先頭、それも無ければ主ディスプレイ。
    public static func displayID(
        at point: CGPoint,
        displays: [MouseDisplayBounds]
    ) -> UInt32 {
        for display in displays where display.bounds.contains(point) {
            return display.displayID
        }
        return displays.first?.displayID ?? CGMainDisplayID()
    }

    /// 点を含むディスプレイ。無ければ先頭。
    public static func display(
        at point: CGPoint,
        displays: [MouseDisplayBounds]
    ) -> MouseDisplayBounds? {
        displays.first(where: { $0.bounds.contains(point) }) ?? displays.first
    }
}

/// 画面キャプチャ 1 回分。
public struct VoiceScreenCaptureResult: Equatable, Sendable {
    public let pngData: Data
    public let displayTitle: String
    public let displayID: UInt32

    public init(pngData: Data, displayTitle: String, displayID: UInt32) {
        self.pngData = pngData
        self.displayTitle = displayTitle
        self.displayID = displayID
    }
}

/// §5-3: マウスがあるディスプレイ 1 枚を撮る（確認ダイアログなし）。
public protocol VoiceScreenCapturing: Sendable {
    func captureMouseDisplayPNG() async throws -> VoiceScreenCaptureResult
}

/// 本番実装。Screen Recording 権限が必要。
public struct LiveVoiceScreenCapture: VoiceScreenCapturing {
    private let mouse: MouseLocationProviding
    private let displays: DisplayBoundsListing
    private let capture: DisplayPNGCapturing
    private let permission: ScreenRecordingPermissionChecking

    public init(
        mouse: MouseLocationProviding = CGEventMouseLocationProvider(),
        displays: DisplayBoundsListing = CGDisplayBoundsListing(),
        capture: DisplayPNGCapturing = LiveDisplayPNGCapture(),
        permission: ScreenRecordingPermissionChecking = LiveScreenRecordingPermissionChecker()
    ) {
        self.mouse = mouse
        self.displays = displays
        self.capture = capture
        self.permission = permission
    }

    public func captureMouseDisplayPNG() async throws -> VoiceScreenCaptureResult {
        let grant = permission.screenRecordingPermission()
        guard grant.grant == .granted else {
            throw CaptureError.screenRecordingPermissionNotGranted(detail: grant.detail)
        }

        let point = mouse.globalMouseLocation()
        let boundsList = displays.displayBounds()
        let selected = MouseDisplaySelector.display(at: point, displays: boundsList)
        let displayID = selected?.displayID ?? CGMainDisplayID()
        let title = selected?.title ?? "ディスプレイ"
        let png = try await capture.captureDisplayPNG(displayID: displayID, title: title)
        return VoiceScreenCaptureResult(pngData: png, displayTitle: title, displayID: displayID)
    }
}

/// 会話 UI 用の小さな PNG サムネイル。
public enum VoiceScreenThumbnail {
    public static func png(from png: Data, maxEdge: Int = 160) -> Data? {
        guard
            let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return png }
        let scale = min(Double(maxEdge) / Double(max(width, height)), 1.0)
        let targetWidth = max(1, Int((Double(width) * scale).rounded()))
        let targetHeight = max(1, Int((Double(height) * scale).rounded()))
        guard
            let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return png
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = context.makeImage() else { return png }
        return try? CaptureImageCodec.pngData(from: scaled)
    }
}

/// `CGGetActiveDisplayList` から bounds 一覧を作る。
public struct CGDisplayBoundsListing: DisplayBoundsListing {
    public init() {}

    public func displayBounds() -> [MouseDisplayBounds] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        CGGetActiveDisplayList(32, &ids, &count)

        let names = NSScreen.screens.reduce(into: [CGDirectDisplayID: String]()) { result, screen in
            guard
                let raw = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")],
                let id = (raw as? NSNumber)?.uint32Value
            else {
                return
            }
            result[id] = screen.localizedName
        }

        var displays: [MouseDisplayBounds] = []
        for index in 0..<Int(count) {
            let id = ids[index]
            displays.append(
                MouseDisplayBounds(
                    displayID: id,
                    bounds: CGDisplayBounds(id),
                    title: names[id] ?? "ディスプレイ \(id)"
                )
            )
        }
        return displays
    }
}
