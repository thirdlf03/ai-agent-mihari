import Foundation

/// ペットのディレクトリに置かれる `pet.json` に対応するメタデータ。
public struct PetManifest: Codable, Hashable, Sendable {
    /// ペットの識別子。ディレクトリ名と一致することを想定する。
    public let id: String
    /// メニューなどに出す表示名。
    public let displayName: String
    /// ペットの説明文。
    public let description: String
    /// `pet.json` と同じディレクトリからの相対パスで書かれたスプライトシートの位置。
    public let spritesheetPath: String
}

/// 素材の置き場所まで解決済みのペット 1 体分。
public struct PetDefinition: Identifiable, Hashable, Sendable {
    /// `pet.json` の内容。
    public let manifest: PetManifest
    /// `pet.json` が置かれているディレクトリ。
    public let directoryURL: URL
    /// セリフを差し替える `speech.json` の位置。置かれていなければ nil。
    public let speechURL: URL?

    public var id: String { manifest.id }

    /// メニューなどに出す表示名。
    public var displayName: String { manifest.displayName }

    /// スプライトシートの実際の位置。
    public var spritesheetURL: URL {
        directoryURL.appendingPathComponent(manifest.spritesheetPath)
    }

    /// カットイン用の画像の位置。置かれていなければ nil。
    ///
    /// `pet.json` には書かず、`cutin/<name>.png` という置き場所の規約だけで解決する。
    public func cutInImageURL(_ image: AttendanceCutInImage) -> URL? {
        let url =
            directoryURL
            .appendingPathComponent("cutin")
            .appendingPathComponent("\(image.rawValue).png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// カットインに必要な画像が 3 枚とも揃っているか。揃っているペットだけが演出を出せる。
    public var hasCutInImages: Bool {
        AttendanceCutInImage.allCases.allSatisfy { cutInImageURL($0) != nil }
    }
}
