import Foundation

/// ファイル系 op（find_files / fetch_file / hand_off_file）が触れてよい範囲。
///
/// 許可ルートは環境変数 `MIHARI_MAC_SEARCH_DIRS`（`:` 区切り、`~` 展開可）。
/// 未設定なら `~/Desktop`・`~/Documents`・`~/Downloads` の 3 つ。
/// 判定は正規化 + symlink 解決後の実体パスに対する包含で行うので、
/// `..` や symlink 越しに許可ルートの外へは出られない。
public struct MacFileAccessPolicy: Sendable {

    /// 許可ルートを上書きする環境変数の名前。
    public static let searchDirsEnvironmentKey = "MIHARI_MAC_SEARCH_DIRS"

    /// 許可ルート（正規化・symlink 解決済みのディレクトリ URL）。
    public let allowedRoots: [URL]

    /// 環境変数から許可ルートを決める既定の作り方。
    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let raw = environment[Self.searchDirsEnvironmentKey]
        let entries = (raw ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if entries.isEmpty {
            self.init(allowedRoots: [
                home.appendingPathComponent("Desktop"),
                home.appendingPathComponent("Documents"),
                home.appendingPathComponent("Downloads"),
            ])
            return
        }
        self.init(allowedRoots: entries.map { Self.fileURL(for: $0) })
    }

    /// 許可ルートを直接渡す作り方（テスト用）。
    public init(allowedRoots: [URL]) {
        self.allowedRoots = allowedRoots.map(Self.normalize)
    }

    /// `url` の実体が許可ルートの内側（またはルート自身）なら true。
    public func allows(_ url: URL) -> Bool {
        let target = Self.normalize(url).path
        return allowedRoots.contains { root in
            target == root.path || target.hasPrefix(root.path + "/")
        }
    }

    /// `find_files` の `dirs` パラメータを、許可ルートの内側に絞った検索先へ写す。
    ///
    /// - `nil` / 空 … 許可ルート全部を返す。
    /// - 指定あり … 許可ルートの内側にあるものだけを残す。1 つも残らなければ
    ///   `MacFileSearchError.noAllowedSearchDir` を投げる。
    public func resolveSearchDirs(param: [String]?) throws -> [URL] {
        guard let param, !param.isEmpty else { return allowedRoots }
        let dirs = param.map { Self.normalize(Self.fileURL(for: $0)) }
        let kept = dirs.filter { allows($0) }
        guard !kept.isEmpty else {
            throw MacFileSearchError.noAllowedSearchDir
        }
        return kept
    }

    /// パス文字列（`~` 可）を file URL へ写す。
    static func fileURL(for rawPath: String) -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    /// 正規化 + symlink 解決。実在しないパスでも standardize は効く。
    static func normalize(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

/// ファイル系 op の失敗。op.result の error.code / message へ写す。
public enum MacFileSearchError: Error, Sendable {
    /// `dirs` で絞った結果、許可ルート内の検索先が 1 つも残らなかった。
    case noAllowedSearchDir
    /// 許可ルートの外のパスを指定された。
    case pathNotAllowed
    /// ファイルが無い / 通常ファイルではない。
    case fileNotFound
    /// `max_bytes` を超える大きさ。
    case fileTooLarge(size: Int64, limit: Int)
    /// Spotlight（NSMetadataQuery）が時間内に応答しなかった / 失敗した。
    case spotlightUnavailable

    /// op.result の error.code。
    public var code: String {
        switch self {
        case .noAllowedSearchDir: return "no_allowed_search_dir"
        case .pathNotAllowed: return "path_not_allowed"
        case .fileNotFound: return "file_not_found"
        case .fileTooLarge: return "file_too_large"
        case .spotlightUnavailable: return "spotlight_unavailable"
        }
    }

    /// op.result の error.message（人間向け・日本語）。
    public var message: String {
        switch self {
        case .noAllowedSearchDir:
            return "指定されたフォルダは許可フォルダの外（MIHARI_MAC_SEARCH_DIRS の内側だけ探せる）"
        case .pathNotAllowed:
            return "そのパスは許可フォルダの外（MIHARI_MAC_SEARCH_DIRS の内側だけ触れる）"
        case .fileNotFound:
            return "ファイルが見つからない（通常ファイルではない可能性）"
        case .fileTooLarge(let size, let limit):
            return "ファイルが大きすぎる（\(size) バイト > max_bytes \(limit)。上限 16MB まで max_bytes を上げられる）"
        case .spotlightUnavailable:
            return "Spotlight が使えない・応答しない（名前検索はフォールバックで探せる）"
        }
    }
}
