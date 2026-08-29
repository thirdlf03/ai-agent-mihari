import CoreGraphics
import Foundation
import ScreenCaptureKit
import os

/// ScreenCaptureKit でメインディスプレイを 1 枚キャプチャする。
///
/// `CGImage` は Sendable ではないため、非同期境界を越える前にこの型の中で
/// PNG データへ変換してしまい、呼び出し側には `Data` だけを渡す。
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
}
