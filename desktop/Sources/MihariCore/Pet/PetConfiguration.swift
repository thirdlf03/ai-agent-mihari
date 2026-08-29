import CoreGraphics
import Foundation

/// ペットの見た目まわりの設定。画像やサイズを差し替え可能にするための入れ物。
public struct PetConfiguration: Sendable, Equatable {
    /// デスクトップ常駐ウィンドウの既定サイズ。
    public static let defaultWindowSize = CGSize(width: 160, height: 160)
    /// 画像が未設定・見つからないときに描く SF Symbols の既定名。
    public static let defaultPlaceholderSymbolName = "cat.fill"

    /// 差し替え用の画像ファイルのパス。`nil` または存在しないパスならプレースホルダを描く。
    public var imagePath: String?
    /// ウィンドウ（画像部分）のサイズ。
    public var windowSize: CGSize
    /// 画像が見つからないときに使う SF Symbols のプレースホルダ名。
    public var placeholderSymbolName: String

    public init(
        imagePath: String? = nil,
        windowSize: CGSize = PetConfiguration.defaultWindowSize,
        placeholderSymbolName: String = PetConfiguration.defaultPlaceholderSymbolName
    ) {
        self.imagePath = imagePath
        self.windowSize = windowSize
        self.placeholderSymbolName = placeholderSymbolName
    }

    public static let `default` = PetConfiguration()
}
