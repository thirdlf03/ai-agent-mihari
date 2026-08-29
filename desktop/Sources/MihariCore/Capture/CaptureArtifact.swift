import Foundation

/// 撮った画像の種類。
public enum CaptureKind: String, Sendable, Equatable {
    case camera
    case screenshot
    /// デーモン経由で取得した iPhone の画面。
    case iphone
}

/// 一時ディレクトリに保存した画像 1 枚。
///
/// 保存先パスと削除の両方をこの型だけで完結させる。Discord への送信が終わったら
/// 呼び出し側が `delete()` を呼び、証拠画像をローカルに残さない(Epic の非目標)。
public struct CaptureArtifact: Sendable, Equatable {
    public let kind: CaptureKind
    public let url: URL
    public let capturedAt: Date

    public init(kind: CaptureKind, url: URL, capturedAt: Date = Date()) {
        self.kind = kind
        self.url = url
        self.capturedAt = capturedAt
    }

    /// 送信後にローカルから削除する。
    ///
    /// 既に消えている場合は成功として扱う(二重に呼ばれても壊れない)。
    public func delete(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw CaptureError.fileDeleteFailed(reason: error.localizedDescription)
        }
    }
}
