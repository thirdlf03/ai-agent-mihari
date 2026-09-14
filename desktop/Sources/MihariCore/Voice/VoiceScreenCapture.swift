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
    /// 実装が `NSScreen.screens` を読むため、メインスレッド寄せにする。
    @MainActor func displayBounds() -> [MouseDisplayBounds]
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
    /// 画像バイト列。形式は `mediaType` が示す（"image/png" / "image/jpeg"）。
    public let data: Data
    /// `data` の MIME タイプ。`input.image` の `media_type` にそのまま使う。
    public let mediaType: String
    public let displayTitle: String
    public let displayID: UInt32

    public init(data: Data, mediaType: String, displayTitle: String, displayID: UInt32) {
        self.data = data
        self.mediaType = mediaType
        self.displayTitle = displayTitle
        self.displayID = displayID
    }

    /// PNG 1 枚の結果を作る。
    public init(pngData: Data, displayTitle: String, displayID: UInt32) {
        self.init(data: pngData, mediaType: "image/png", displayTitle: displayTitle, displayID: displayID)
    }
}

/// §5-3: マウスがあるディスプレイ 1 枚を撮る（確認ダイアログなし）。
public protocol VoiceScreenCapturing: Sendable {
    func captureMouseDisplayPNG() async throws -> VoiceScreenCaptureResult
    /// live_audio 用の縮小 JPEG。backend の入力履歴上限に収めるため
    /// `maxBytes` 以下を目指して縮小・再圧縮する。
    func captureMouseDisplayJPEG(maxBytes: Int) async throws -> VoiceScreenCaptureResult
}

extension VoiceScreenCapturing {
    /// 既定実装: PNG を撮ってから縮小 JPEG へ変換する。
    /// JPEG を直接撮れる実装は差し替えてよい。
    public func captureMouseDisplayJPEG(maxBytes: Int) async throws -> VoiceScreenCaptureResult {
        let png = try await captureMouseDisplayPNG()
        guard let jpeg = VoiceScreenDownscaleJPEG.jpegData(from: png.data, maxBytes: maxBytes) else {
            throw CaptureError.imageEncodingFailed
        }
        return VoiceScreenCaptureResult(
            data: jpeg,
            mediaType: "image/jpeg",
            displayTitle: png.displayTitle,
            displayID: png.displayID
        )
    }
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
        let boundsList = await displays.displayBounds()
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

/// live_audio の入力履歴上限へ収めるための縮小 JPEG 変換。
///
/// 長辺 `maxEdge` まで縮めてから画質を段階的に下げ、`maxBytes` 以下を目指す。
/// それでも収まらなければ半分の辺でやり直し、最後はいちばん小さくなったものを返す。
public enum VoiceScreenDownscaleJPEG {
    /// 試す JPEG 品質。先に試す順で、最初に `maxBytes` を下回ったものを採用する。
    private static let qualitySteps: [CGFloat] = [0.6, 0.45, 0.3, 0.18, 0.08]

    /// PNG / JPEG などの画像データを縮小 JPEG にする。デコードできなければ nil。
    public static func jpegData(
        from source: Data,
        maxEdge: Int = 320,
        maxBytes: Int = 12_000
    ) -> Data? {
        guard
            let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            return nil
        }
        var smallest: Data?
        for edge in [maxEdge, maxEdge / 2] where edge > 0 {
            guard let scaled = scaledImage(image, maxEdge: edge) else { continue }
            for quality in qualitySteps {
                guard let jpeg = jpegData(scaled, quality: quality) else { continue }
                if jpeg.count <= maxBytes { return jpeg }
                if smallest.map({ jpeg.count < $0.count }) ?? true {
                    smallest = jpeg
                }
            }
        }
        return smallest
    }

    /// 長辺が `maxEdge` を超えないよう縮小する。既に小さければそのまま返す。
    private static func scaledImage(_ image: CGImage, maxEdge: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
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
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    /// `CGImage` を指定品質の JPEG データにする。
    private static func jpegData(_ image: CGImage, quality: CGFloat) -> Data? {
        NSBitmapImageRep(cgImage: image)
            .representation(using: .jpeg, properties: [.compressionFactor: quality])
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
