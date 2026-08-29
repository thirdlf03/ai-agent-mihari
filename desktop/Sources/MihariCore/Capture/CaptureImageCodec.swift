import AppKit
import CoreGraphics
import Foundation

/// 画像データと `CGImage` の相互変換。
///
/// カメラ(JPEG 相当のバイト列)とスクリーンショット(`CGImage`)で入力の形が違うため、
/// 保存直前に必ずここを通して PNG データへ揃える。
public enum CaptureImageCodec {

    /// カメラの撮影データ(JPEG など)から `CGImage` を復元する。
    public static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw CaptureError.imageDecodingFailed
        }
        return image
    }

    /// `CGImage` を PNG データへ変換する。
    public static func pngData(from image: CGImage) throws -> Data {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw CaptureError.imageEncodingFailed
        }
        return data
    }

    /// プレビュー表示用に `CGImage` を `NSImage` へ変換する。
    public static func nsImage(from image: CGImage) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
