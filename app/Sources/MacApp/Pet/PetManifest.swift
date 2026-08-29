import Foundation

/// ペットのディレクトリに置かれる `pet.json` に対応するメタデータ。
struct PetManifest: Codable, Hashable {
    /// ペットの識別子。ディレクトリ名と一致することを想定する。
    let id: String
    /// メニューなどに出す表示名。
    let displayName: String
    /// ペットの説明文。
    let description: String
    /// `pet.json` と同じディレクトリからの相対パスで書かれたスプライトシートの位置。
    let spritesheetPath: String
}

/// 素材の置き場所まで解決済みのペット 1 体分。
struct PetDefinition: Identifiable, Hashable {
    /// `pet.json` の内容。
    let manifest: PetManifest
    /// `pet.json` が置かれているディレクトリ。
    let directoryURL: URL
    /// セリフを差し替える `speech.json` の位置。置かれていなければ nil。
    let speechURL: URL?

    var id: String { manifest.id }

    /// メニューなどに出す表示名。
    var displayName: String { manifest.displayName }

    /// スプライトシートの実際の位置。
    var spritesheetURL: URL {
        directoryURL.appendingPathComponent(manifest.spritesheetPath)
    }
}
