import Foundation

/// 依頼に添える Mac スクショ 1 枚（#22）。
///
/// 撮影直後の PNG バイト列と、Retina・複数画面のメタデータを持つ。指定工作の
/// プレビュー表示と削除、送信（base64 の JSON）のどちらにもこの 1 型で足りる。
/// スクショは成果物の公開対象ではない。送信先（部屋）の `input/screenshots/` に
/// 保存され、Hermes へはバイト列（data URI）で渡る。
public struct ScreenshotAttachment: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let filename: String
    public let pngData: Data
    public let sourceKind: ScreenshotSourceKind
    public let sourceTitle: String
    public let displayID: UInt32
    public let windowID: UInt32?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let pointWidth: Double?
    public let pointHeight: Double?
    public let backingScale: Double?
    public let frameX: Double?
    public let frameY: Double?
    public let capturedAt: Date

    public init(
        id: UUID = UUID(),
        filename: String,
        pngData: Data,
        sourceKind: ScreenshotSourceKind = .display,
        sourceTitle: String,
        displayID: UInt32,
        windowID: UInt32? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        pointWidth: Double? = nil,
        pointHeight: Double? = nil,
        backingScale: Double? = nil,
        frameX: Double? = nil,
        frameY: Double? = nil,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.filename = filename
        self.pngData = pngData
        self.sourceKind = sourceKind
        self.sourceTitle = sourceTitle
        self.displayID = displayID
        self.windowID = windowID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.backingScale = backingScale
        self.frameX = frameX
        self.frameY = frameY
        self.capturedAt = capturedAt
    }

    /// 撮影結果から作る。ファイル名は撮影元で分かる名前にする（重複を避けるため短い UUID を足す）。
    public init(capture: ScreenshotCapture, now: Date = Date()) {
        let suffix = capture.windowID.map { "window-\($0)" } ?? "display-\(capture.displayID)"
        self.init(
            filename: "screenshot-\(UUID().uuidString.prefix(8))-\(suffix).png",
            pngData: capture.pngData,
            sourceKind: capture.kind,
            sourceTitle: capture.title,
            displayID: capture.displayID,
            windowID: capture.windowID,
            pixelWidth: capture.pixelWidth,
            pixelHeight: capture.pixelHeight,
            pointWidth: capture.pointWidth,
            pointHeight: capture.pointHeight,
            backingScale: capture.backingScale,
            frameX: capture.frameX,
            frameY: capture.frameY,
            capturedAt: now
        )
    }
}

/// `POST /jobs` と `POST /jobs/{id}/followup` に載せるスクショ 1 枚の JSON 形。
///
/// バイト列は `content_base64` に base64 で載せる。パス文字列だけを本文へ書く
/// 送り方はしない（部屋がバイト列を multimodal 入力に載せる）。
public struct ScreenshotUploadPayload: Equatable, Sendable {
    public let filename: String
    public let mediaType: String
    public let contentBase64: Data
    public let source: String
    public let sourceTitle: String
    public let displayID: UInt32?
    public let windowID: UInt32?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let pointWidth: Double?
    public let pointHeight: Double?
    public let backingScale: Double?
    public let frameX: Double?
    public let frameY: Double?

    public init(attachment: ScreenshotAttachment, mediaType: String = "image/png") {
        self.filename = attachment.filename
        self.mediaType = mediaType
        self.contentBase64 = attachment.pngData
        self.source = attachment.sourceKind.rawValue
        self.sourceTitle = attachment.sourceTitle
        self.displayID = attachment.displayID
        self.windowID = attachment.windowID
        self.pixelWidth = attachment.pixelWidth
        self.pixelHeight = attachment.pixelHeight
        self.pointWidth = attachment.pointWidth
        self.pointHeight = attachment.pointHeight
        self.backingScale = attachment.backingScale
        self.frameX = attachment.frameX
        self.frameY = attachment.frameY
    }
}

extension ScreenshotUploadPayload: Encodable {
    enum CodingKeys: String, CodingKey {
        case filename
        case mediaType = "media_type"
        case contentBase64 = "content_base64"
        case source
        case sourceTitle = "source_title"
        case displayID = "display_id"
        case windowID = "window_id"
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
        case pointWidth = "point_width"
        case pointHeight = "point_height"
        case backingScale = "backing_scale"
        case frameX = "frame_x"
        case frameY = "frame_y"
    }
}
