import AppKit
import CoreGraphics
import Foundation

/// スプライトシートの並び。全ペット共通で 8 列 × 9 行、1 セル 192 × 208 px。
enum PetSpriteGrid {
    static let columns = 8
    static let rows = 9
    static let cellWidth = 192
    static let cellHeight = 208

    /// スプライトシート全体の幅(px)。
    static var sheetWidth: Int { columns * cellWidth }

    /// スプライトシート全体の高さ(px)。
    static var sheetHeight: Int { rows * cellHeight }

    /// 1 コマの大きさ。ウィンドウの大きさはこれに表示倍率を掛けて決める。
    static var cellSize: CGSize {
        CGSize(width: CGFloat(cellWidth), height: CGFloat(cellHeight))
    }
}

/// スプライトシートの 1 行に対応するアニメーション。いずれも末尾まで進んだら先頭へ戻ってループする。
public enum PetAnimation: String, CaseIterable, Sendable {
    /// 待機。
    case idle
    /// 右へ歩く。
    case runningRight
    /// 左へ歩く。左向き専用の行があるので鏡映はしない。
    case runningLeft
    /// 手を振る。
    case waving
    /// 跳ねる。
    case jumping
    /// 失敗して落ち込む。
    case failed
    /// 入力を待つ。
    case waiting
    /// 作業に集中する(足で走る意味ではない)。
    case running
    /// 内容を確認する。
    case review

    /// スプライトシート上の行番号(0 始まり)。
    var row: Int {
        switch self {
        case .idle: return 0
        case .runningRight: return 1
        case .runningLeft: return 2
        case .waving: return 3
        case .jumping: return 4
        case .failed: return 5
        case .waiting: return 6
        case .running: return 7
        case .review: return 8
        }
    }

    /// 各コマの表示時間(秒)。要素数がそのままコマ数になる。
    var frameDurations: [TimeInterval] {
        switch self {
        case .idle: return [0.280, 0.110, 0.110, 0.140, 0.140, 0.320]
        case .runningRight, .runningLeft: return [0.120, 0.120, 0.120, 0.120, 0.120, 0.120, 0.120, 0.220]
        case .waving: return [0.140, 0.140, 0.140, 0.280]
        case .jumping: return [0.140, 0.140, 0.140, 0.140, 0.280]
        case .failed: return [0.140, 0.140, 0.140, 0.140, 0.140, 0.140, 0.140, 0.240]
        case .waiting: return [0.150, 0.150, 0.150, 0.150, 0.150, 0.260]
        case .running: return [0.120, 0.120, 0.120, 0.120, 0.120, 0.220]
        case .review: return [0.150, 0.150, 0.150, 0.150, 0.150, 0.280]
        }
    }

    /// コマ数。
    var frameCount: Int { frameDurations.count }
}

/// ペットのスプライトシートを読み込み、アニメーションごとのコマ画像に切り出して保持する。
@MainActor
final class PetAtlas {
    /// 切り出し元のペット。
    let definition: PetDefinition

    private let frames: [PetAnimation: [CGImage]]

    /// スプライトシートを読み込み、全アニメーションのコマを切り出す。
    init(definition: PetDefinition) throws {
        let sheet = try Self.loadSheet(at: definition.spritesheetURL)
        var frames: [PetAnimation: [CGImage]] = [:]
        for animation in PetAnimation.allCases {
            frames[animation] = try Self.crop(sheet: sheet, animation: animation)
        }
        self.definition = definition
        self.frames = frames
    }

    /// 指定したアニメーションの `index` コマ目。範囲外の index は先頭へ巻き戻して扱う。
    func frame(_ animation: PetAnimation, at index: Int) -> CGImage? {
        guard let images = frames[animation], !images.isEmpty else { return nil }
        return images[max(0, index) % images.count]
    }

    /// スプライトシートを `CGImage` として読み込み、想定どおりの大きさか検証する。
    private static func loadSheet(at url: URL) throws -> CGImage {
        guard let image = NSImage(contentsOf: url) else {
            throw PetAtlasError.unreadableSpritesheet(url: url)
        }
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let sheet = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            throw PetAtlasError.unreadableSpritesheet(url: url)
        }
        guard sheet.width == PetSpriteGrid.sheetWidth, sheet.height == PetSpriteGrid.sheetHeight else {
            throw PetAtlasError.unexpectedSpritesheetSize(width: sheet.width, height: sheet.height)
        }
        return sheet
    }

    /// 1 行分のコマを左上原点で切り出す。
    private static func crop(sheet: CGImage, animation: PetAnimation) throws -> [CGImage] {
        try (0..<animation.frameCount).map { column in
            let rect = CGRect(
                x: column * PetSpriteGrid.cellWidth,
                y: animation.row * PetSpriteGrid.cellHeight,
                width: PetSpriteGrid.cellWidth,
                height: PetSpriteGrid.cellHeight
            )
            guard let frame = sheet.cropping(to: rect) else {
                throw PetAtlasError.croppingFailed(animation: animation, column: column)
            }
            return frame
        }
    }
}

/// スプライトシートの読み込みに失敗した理由。
enum PetAtlasError: LocalizedError {
    case unreadableSpritesheet(url: URL)
    case unexpectedSpritesheetSize(width: Int, height: Int)
    case croppingFailed(animation: PetAnimation, column: Int)

    var errorDescription: String? {
        switch self {
        case .unreadableSpritesheet(let url):
            return "スプライトシートを読み込めません: \(url.path)"
        case .unexpectedSpritesheetSize(let width, let height):
            let expected = "\(PetSpriteGrid.sheetWidth)×\(PetSpriteGrid.sheetHeight)"
            return "スプライトシートの大きさが \(expected) ではありません: \(width)×\(height)"
        case .croppingFailed(let animation, let column):
            return "コマの切り出しに失敗しました: \(animation.rawValue) の \(column) 列目"
        }
    }
}
