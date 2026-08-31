import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import MihariCore

/// 保存されたスクショにスプライトを描き足す処理を検証する。
///
/// `NSMetadataQuery` の見張りはヘッドレスでは当てにならないので触らない。
/// 置き場所の計算(純粋関数)と、実ファイルへの合成だけを見る。
@Suite("スクショへの写り込み")
@MainActor
struct ScreenshotPhotobombTests {

    private typealias Compositor = ScreenshotPhotobombCompositor

    /// スプライト 1 コマの大きさ(192 × 208 px)。
    private static let spriteSize = CGSize(width: 192, height: 208)
    /// スクショに見立てた大きさ。合成の検証で全画素を突き合わせるので、小さく取る。
    private static let imageSize = CGSize(width: 300, height: 200)

    // MARK: - 置き場所

    @Test("高さはスクショの高さの 22% で、比率は崩さない")
    func scalesToTwentyTwoPercentOfHeight() {
        let rect = Compositor.placement(
            spriteSize: Self.spriteSize,
            imageSize: Self.imageSize,
            isRight: false
        )

        #expect(rect.height == Self.imageSize.height * 0.22)
        let expectedWidth = rect.height * (Self.spriteSize.width / Self.spriteSize.height)
        #expect(abs(rect.width - expectedWidth) < 0.0001)
    }

    @Test("下端から高さの 8% はみ出させる", arguments: [false, true])
    func overhangsBottomByEightPercent(isRight: Bool) {
        let rect = Compositor.placement(
            spriteSize: Self.spriteSize,
            imageSize: Self.imageSize,
            isRight: isRight
        )

        // 左下原点なので、下へはみ出すぶんだけ y が負になる。
        #expect(abs(rect.minY - (-rect.height * 0.08)) < 0.0001)
        #expect(rect.minY < 0)
    }

    @Test("左下に置くときは左端から幅の 5% 内側")
    func insetsFromLeftEdge() {
        let rect = Compositor.placement(
            spriteSize: Self.spriteSize,
            imageSize: Self.imageSize,
            isRight: false
        )

        #expect(abs(rect.minX - rect.width * 0.05) < 0.0001)
    }

    @Test("右下に置くときは右端から幅の 5% 内側")
    func insetsFromRightEdge() {
        let rect = Compositor.placement(
            spriteSize: Self.spriteSize,
            imageSize: Self.imageSize,
            isRight: true
        )

        #expect(abs(rect.maxX - (Self.imageSize.width - rect.width * 0.05)) < 0.0001)
    }

    @Test("高さ 0 のスプライトでも 0 除算しない")
    func degenerateSpriteDoesNotDivideByZero() {
        let rect = Compositor.placement(
            spriteSize: CGSize(width: 10, height: 0),
            imageSize: Self.imageSize,
            isRight: false
        )

        #expect(rect.height == Self.imageSize.height * 0.22)
        #expect(rect.width == rect.height)
    }

    // MARK: - 合成

    @Test("合成しても画像の大きさと形式は変わらず、スプライトの領域だけが変わる")
    func compositeKeepsSizeAndChangesOnlySpriteArea() throws {
        let sprite = try Self.bundledSprite()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        try Self.writeSolidPNG(size: Self.imageSize, to: url)
        let before = try #require(Compositor.read(url))
        let beforePixels = try #require(Self.pixels(of: before.image))

        #expect(Compositor.write(sprite: sprite, into: before, at: url, isRight: false))

        let after = try #require(Compositor.read(url))
        // 大きさと形式は元のまま。
        #expect(after.image.width == before.image.width)
        #expect(after.image.height == before.image.height)
        #expect(after.type == UTType.png.identifier)

        let afterPixels = try #require(Self.pixels(of: after.image))
        #expect(afterPixels.count == beforePixels.count)

        // 変わったピクセルを数え、それがスプライトの矩形の中に収まっているかを見る。
        let rect = Compositor.placement(
            spriteSize: CGSize(width: sprite.width, height: sprite.height),
            imageSize: CGSize(width: after.image.width, height: after.image.height),
            isRight: false
        )
        var changed = 0
        var outside = 0
        let width = after.image.width
        let height = after.image.height
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let same = (0..<4).allSatisfy { beforePixels[offset + $0] == afterPixels[offset + $0] }
                guard !same else { continue }
                changed += 1
                // ピクセルバッファは上が原点、矩形は下が原点。上下を読み替えて突き合わせる。
                let flippedY = CGFloat(height - y)
                let inside =
                    CGFloat(x) >= rect.minX - 1 && CGFloat(x) <= rect.maxX + 1
                    && flippedY >= rect.minY - 1 && flippedY <= rect.maxY + 1
                if !inside { outside += 1 }
            }
        }
        #expect(changed > 0)
        #expect(outside == 0)
    }

    /// 同梱ペットの待機 1 コマ目。合成に実際に使うコマ。
    private static func bundledSprite() throws -> CGImage {
        let pets = PetLibrary.availablePets()
        let pet = try #require(PetLibrary.pet(id: nil, in: pets))
        let atlas = try PetAtlas(definition: pet)
        return try #require(atlas.frame(.idle, at: 0))
    }

    /// スクショに見立てた無地の PNG を書く。
    private static func writeSolidPNG(size: CGSize, to url: URL) throws {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        let image = try #require(context.makeImage())
        try CaptureImageCodec.pngData(from: image).write(to: url)
    }

    /// 画素を 8bit RGBA(上が原点)で取り出す。比較のために形を揃えるためだけの変換。
    private static func pixels(of image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? buffer : nil
    }
}
