import Foundation

/// 実際に描く画像の出どころ。
public enum PetImageSource: Equatable, Sendable {
    /// ファイルパスから読み込む本物の画像。
    case file(path: String)
    /// 画像が無いときに描く SF Symbols のプレースホルダ。
    case symbol(name: String)
}

/// 設定された画像パスが使えるかどうかを判定し、使えなければプレースホルダへ落とす。
public enum PetImageResolver {
    /// - Parameter fileExists: パスの実在チェック。テストでは差し替えて、実ファイルシステムに
    ///   触らずに判定ロジックだけを検証できるようにする。
    public static func resolve(
        configuration: PetConfiguration,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> PetImageSource {
        guard let path = configuration.imagePath, !path.isEmpty, fileExists(path) else {
            return .symbol(name: configuration.placeholderSymbolName)
        }
        return .file(path: path)
    }
}
