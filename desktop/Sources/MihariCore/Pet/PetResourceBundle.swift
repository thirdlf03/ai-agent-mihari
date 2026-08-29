import Foundation

/// `MihariCore` に同梱したリソース（`Resources/pets`）が入ったバンドルを探す。
///
/// SwiftPM が生成する `Bundle.module` は「実行ファイルの隣」と「ビルド時の絶対パス」しか見ない。
/// `build.sh` が組み立てる `Mihari.app` ではバンドルを `Contents/Resources` に置く（`.app` 直下に
/// 置くと `codesign --verify --strict` が落ちる）ため、`Bundle.module` では見つからず落ちる。
/// そのため探索は自前で行い、`Bundle.module` は最後の保険としてだけ使う。
enum PetResourceBundle {
    /// SwiftPM がリソースバンドルに付ける名前（`<パッケージ名>_<ターゲット名>.bundle`）。
    static let bundleName = "Mihari_MihariCore.bundle"

    /// リソースバンドルを探す。見つからなければ nil。
    static func locate() -> Bundle? {
        var candidates: [URL] = []
        // 署名済みの .app（Contents/Resources に置いてある）。
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(bundleName))
        }
        // swift run で直接実行した場合（実行ファイルの隣）。
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(bundleName))
        // swift test の場合（xctest バンドルの隣）。
        let ownBundleURL = Bundle(for: PetResourceBundleToken.self).bundleURL
        candidates.append(ownBundleURL.deletingLastPathComponent().appendingPathComponent(bundleName))

        for url in candidates {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return Bundle.module
    }
}

/// `Bundle(for:)` で自分の入っているバンドルを引くためだけのクラス。
private final class PetResourceBundleToken {}
