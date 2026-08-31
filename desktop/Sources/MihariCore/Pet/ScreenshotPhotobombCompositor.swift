import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// 保存されたスクリーンショットに、ペットのスプライトを 1 コマ描き足す。
///
/// 撮影の瞬間に画面へ立ち絵を出す方式は、範囲選択やウィンドウ撮影では写らないうえに
/// 撮る側の邪魔にもなる。撮り終えたファイルへ後から描き込めば、どの撮り方でも必ず写る。
/// 上書きは元の形式(png / jpg / heic)のまま、同じパスへ。
@MainActor
public final class ScreenshotPhotobombCompositor {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "photobomb")

    /// スクショの高さに対するスプライトの高さの割合。
    private static let heightRatio: CGFloat = 0.22
    /// スクショの下端から下へはみ出させる量(スプライトの高さに対する割合)。
    private static let bottomOverhangRatio: CGFloat = 0.08
    /// スクショの左右の端から内側へ寄せる量(スプライトの幅に対する割合)。
    private static let sideInsetRatio: CGFloat = 0.05
    /// 書き込み途中で読めなかったときに、読み直すまで待つ時間(秒)。
    private static let retryDelaySeconds: TimeInterval = 0.5
    /// セリフを言う間隔の下限(秒)。連続でスクショを撮られても喋り続けないようにする。
    private static let speechCooldownSeconds: TimeInterval = 30

    /// 写り込んだときのセリフ。
    static let lines = [
        "スクショ？あたしも一緒に写るからね",
        "なに保存しようとしてるの？あたしにも見せて？",
        "ふふ、記録に残るのはあたしとの思い出だよ",
        "隠しても無駄だよ、あたし写り込むから",
    ]

    /// 一度切り出したコマ。毎回スプライトシートを読み直す理由がない。
    private var sprite: CGImage?
    private var lastSpokeAt: Date?
    private let say: (String) -> Void

    /// - Parameter say: セリフを言わせる口。ペットの吹き出しに繋ぐ。
    public init(say: @escaping (String) -> Void) {
        self.say = say
    }

    /// スクショにスプライトを描き足して同じパスへ上書きし、成功したらセリフを言う。
    ///
    /// 写り込みは余興なので、読めない・書けないはログだけ残して黙って諦める。
    public func photobomb(_ url: URL) async {
        guard let sprite = loadSprite() else { return }

        var source = Self.read(url)
        if source == nil {
            // 撮った直後はまだ書き込み中のことがある。1 回だけ待って読み直す。
            try? await Task.sleep(for: .seconds(Self.retryDelaySeconds))
            source = Self.read(url)
        }
        guard let source else {
            Self.logger.notice("スクショを読めないので写り込みはやらない: \(url.lastPathComponent, privacy: .public)")
            return
        }

        guard Self.write(sprite: sprite, into: source, at: url) else {
            Self.logger.notice("スクショを書き戻せなかった: \(url.lastPathComponent, privacy: .public)")
            return
        }
        sayLineIfNeeded()
    }

    /// スプライトを描く矩形。ピクセル座標、左下原点(`CGContext` と同じ向き)。
    ///
    /// 高さをスクショの高さの割合で決め、比率を保ったまま左下か右下へ寄せる。
    /// 下端から少しはみ出させて、通りすがりに半分だけ写り込んだように見せる。
    static func placement(spriteSize: CGSize, imageSize: CGSize, isRight: Bool) -> CGRect {
        let height = imageSize.height * heightRatio
        let width = spriteSize.height > 0 ? height * (spriteSize.width / spriteSize.height) : height
        let y = -height * bottomOverhangRatio
        let inset = width * sideInsetRatio
        let x = isRight ? imageSize.width - width - inset : inset
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// セリフを 1 つ言う。前に言ってから間が空いていなければ黙る。
    private func sayLineIfNeeded() {
        let now = Date()
        if let lastSpokeAt, now.timeIntervalSince(lastSpokeAt) < Self.speechCooldownSeconds { return }
        guard let line = Self.lines.randomElement() else { return }
        lastSpokeAt = now
        say(line)
    }

    /// 既定のペットのスプライトシートから、待機の先頭コマを切り出す。
    ///
    /// 待機は正面を向いているので、左下でも右下でも据わりが良い。
    private func loadSprite() -> CGImage? {
        if let sprite { return sprite }
        guard let pet = PetLibrary.pet(id: nil, in: PetLibrary.availablePets()) else {
            Self.logger.error("ペットが 1 体も見つからないので写り込みはやらない")
            return nil
        }
        do {
            let atlas = try PetAtlas(definition: pet)
            guard let frame = atlas.frame(.idle, at: 0) else {
                Self.logger.error("待機のコマを取り出せないので写り込みはやらない")
                return nil
            }
            sprite = frame
            return frame
        } catch {
            Self.logger.error("スプライトシートを読めない: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// スクショを読む。形式(UTType)も一緒に返す ―― 書き戻すときに変えないため。
    static func read(_ url: URL) -> SourceImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        // 形式が読めないことはまず無いが、読めなければ png として書き戻す。
        let type = (CGImageSourceGetType(source) as String?) ?? UTType.png.identifier
        return SourceImage(image: image, type: type)
    }

    /// スプライトを描き足して同じパスへ上書きする。
    ///
    /// Retina のスクショは論理サイズの 2 倍のピクセルを持つので、合成はすべてピクセル座標で行う。
    /// ポイント座標で描くと、スプライトだけ半分の大きさになる。
    ///
    /// - Parameter isRight: 右下に置くか。既定では 1 枚ごとに選ぶ ―― 毎回同じ隅から
    ///   出てくるより落ち着きが無くて良い。
    static func write(
        sprite: CGImage,
        into source: SourceImage,
        at url: URL,
        isRight: Bool = .random()
    ) -> Bool {
        let image = source.image
        let imageSize = CGSize(width: image.width, height: image.height)
        guard let context = makeContext(size: imageSize, like: image) else { return false }

        context.draw(image, in: CGRect(origin: .zero, size: imageSize))
        let spriteSize = CGSize(width: sprite.width, height: sprite.height)
        let rect = placement(spriteSize: spriteSize, imageSize: imageSize, isRight: isRight)
        context.draw(sprite, in: rect)

        guard let composed = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                source.type as CFString,
                1,
                nil
            )
        else {
            return false
        }
        CGImageDestinationAddImage(destination, composed, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// 合成用のビットマップ。色空間は元画像のものを引き継ぐ(RGB でなければ sRGB に倒す)。
    private static func makeContext(size: CGSize, like image: CGImage) -> CGContext? {
        let colorSpace =
            image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let colorSpace else { return nil }
        return CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// 読み込んだスクショ 1 枚。形式は上書きのときにそのまま使う。
    struct SourceImage {
        let image: CGImage
        let type: String
    }
}
