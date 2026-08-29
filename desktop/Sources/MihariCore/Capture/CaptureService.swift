import Foundation

/// カメラ撮影とスクリーンショット撮影の窓口。
///
/// 検知が発火したときに呼ぶ入り口をこの 1 型にまとめ、`CaptureView` や
/// 将来のデーモン連携(#9)からは撮影方式の違いを意識せず使えるようにする。
public final class CaptureService: Sendable {

    private let camera: CameraCaptureService
    private let directory: URL

    public init(
        camera: CameraCaptureService = CameraCaptureService(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.camera = camera
        self.directory = CaptureFileStore.directory(temporaryDirectory: temporaryDirectory)
    }

    /// カメラで 1 枚撮り、PNG として一時ディレクトリへ保存する。
    public func capturePhoto() async throws -> CaptureArtifact {
        let jpegData = try await camera.captureSinglePhoto()
        let image = try CaptureImageCodec.decode(jpegData)
        let pngData = try CaptureImageCodec.pngData(from: image)
        let url = try CaptureFileStore.write(pngData, kind: .camera, directory: directory)
        return CaptureArtifact(kind: .camera, url: url)
    }

    /// メインディスプレイのスクリーンショットを 1 枚撮り、PNG として一時ディレクトリへ保存する。
    public func captureScreenshot() async throws -> CaptureArtifact {
        let pngData = try await ScreenshotCaptureService.captureMainDisplayPNG()
        let url = try CaptureFileStore.write(pngData, kind: .screenshot, directory: directory)
        return CaptureArtifact(kind: .screenshot, url: url)
    }
}
