import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import MihariCore

@Suite("画像データの相互変換")
struct CaptureImageCodecTests {

    /// 実カメラ・実画面に依存しない、テスト用の単色 CGImage を作る。
    private static func makeTestImage(width: Int = 4, height: Int = 4) -> CGImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    @Test("CGImage を PNG のシグネチャ付きデータへエンコードできる")
    func encodesToPNG() throws {
        let image = Self.makeTestImage()
        let data = try CaptureImageCodec.pngData(from: image)
        #expect(!data.isEmpty)
        #expect(data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    @Test("PNG エンコード後に decode すると同じピクセルサイズに戻る")
    func roundTripsThroughPNG() throws {
        let image = Self.makeTestImage(width: 6, height: 3)
        let data = try CaptureImageCodec.pngData(from: image)
        let decoded = try CaptureImageCodec.decode(data)
        #expect(decoded.width == 6)
        #expect(decoded.height == 3)
    }

    @Test("壊れたデータを decode すると imageDecodingFailed になる")
    func decodingInvalidDataThrows() {
        #expect(throws: CaptureError.imageDecodingFailed) {
            try CaptureImageCodec.decode(Data([0x00, 0x01, 0x02]))
        }
    }

    @Test("nsImage はピクセルサイズをそのまま引き継ぐ")
    func nsImageKeepsPixelSize() {
        let image = Self.makeTestImage(width: 10, height: 5)
        let nsImage = CaptureImageCodec.nsImage(from: image)
        #expect(nsImage.size.width == 10)
        #expect(nsImage.size.height == 5)
    }
}
