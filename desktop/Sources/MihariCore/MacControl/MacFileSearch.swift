import AppKit
import Foundation

/// 許可フォルダの内側だけを探す・読むための実装主体。
///
/// シェルは一切使わない。
/// - 名前検索 … `FileManager` の列挙でファイル名を照合する
/// - 本文検索 … Spotlight(`NSMetadataQuery`)を先に試し、使えなければ小さなファイルへの
///   上限つきテキスト走査へフォールバックする
/// - 取り込み … 先頭 `maxBytes` だけ読み、超えた分は `truncated` で表す
public enum MacLocalFileSearch {

    /// 検索結果 1 件。op.result の `files[]` にそのまま載る形へ写す。
    public struct Entry: Sendable {
        public let name: String
        public let path: String
        /// ファイル種別の表示名（例: "プレーンテキスト"）。取れなければ拡張子や "file"。
        public let kind: String
        /// バイト数。取れなければ 0。
        public let size: Int64

        public var dictionary: [String: Any] {
            ["name": name, "path": path, "kind": kind, "size": size]
        }
    }

    /// 1 回の列挙で見る項目数の上限。巨大なフォルダで止まらないよう決めておく。
    private static let maxVisitedEntries = 20_000
    /// 本文走査で開くファイルの上限数。
    private static let maxContentScannedFiles = 3_000
    /// 本文走査で 1 ファイルから読む最大バイト数。これを超えるファイルは先頭だけ見る。
    private static let maxContentBytesPerFile = 4 * 1024 * 1024
    /// 本文走査全体にかける時間の上限(秒)。
    private static let contentScanTimeBudget: TimeInterval = 8
    /// Spotlight の応答を待つ時間(秒)。これを超えたらそこまでの結果で返す。
    private static let spotlightTimeoutSeconds: TimeInterval = 6

    // MARK: - 検索

    /// `find_files` の本体。`dirs` はポリシーが許可ルート内へ絞り済みのものだけ来る。
    public static func find(query: String, scope: String, dirs: [URL], limit: Int) async -> [Entry] {
        switch scope {
        case "content":
            if let hits = await spotlightSearch(query: query, dirs: dirs, limit: limit),
                !hits.isEmpty
            {
                return hits
            }
            return findByContentScan(query: query, dirs: dirs, limit: limit)
        default:
            return findByName(query: query, dirs: dirs, limit: limit)
        }
    }

    /// ファイル名（拡張子抜き・あり両方）で大文字小文字を無視して照合する。
    private static func findByName(query: String, dirs: [URL], limit: Int) -> [Entry] {
        var entries: [Entry] = []
        enumerate(dirs: dirs) { url in
            guard entries.count < limit else { return .stop }
            let name = url.lastPathComponent
            let stem = url.deletingPathExtension().lastPathComponent
            guard
                name.localizedCaseInsensitiveContains(query)
                    || stem.localizedCaseInsensitiveContains(query)
            else { return .next }
            entries.append(makeEntry(url))
            return .next
        }
        return entries
    }

    /// Spotlight で本文を探す。起動できないときだけ nil を返し、呼び出し側が走査へ倒す。
    /// 時間内に集まり切らなければ、その時点で見つかっている分を返す（0 件なら走査へ倒す）。
    @MainActor
    private static func spotlightSearch(query: String, dirs: [URL], limit: Int) async -> [Entry]? {
        await withCheckedContinuation { continuation in
            let metadataQuery = NSMetadataQuery()
            metadataQuery.predicate = NSPredicate(
                format: "%K LIKE[cd] %@",
                NSMetadataItemTextContentKey,
                "*\(query)*"
            )
            metadataQuery.searchScopes = dirs

            var resumed = false
            var observer: NSObjectProtocol?

            // 収集完了・タイムアウトのどちらからでも 1 回だけ結果を返す。両方メインで動くので競合しない。
            func finish() {
                guard !resumed else { return }
                resumed = true
                if let observer { NotificationCenter.default.removeObserver(observer) }
                metadataQuery.disableUpdates()
                metadataQuery.stop()
                let count = min(metadataQuery.resultCount, limit)
                let entries = (0..<count).compactMap { index -> Entry? in
                    guard
                        let item = metadataQuery.result(at: index) as? NSMetadataItem,
                        let rawPath = item.value(forAttribute: NSMetadataItemPathKey) as? String
                    else { return nil }
                    return makeEntry(URL(fileURLWithPath: rawPath))
                }
                continuation.resume(returning: entries)
            }

            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: metadataQuery,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { finish() }
            }

            let timeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.spotlightTimeoutSeconds))
                guard !Task.isCancelled else { return }
                finish()
            }

            // start() はメインランループで回す。false なら Spotlight 自体が使えない。
            if !metadataQuery.start() {
                timeout.cancel()
                if let observer { NotificationCenter.default.removeObserver(observer) }
                continuation.resume(returning: nil)
            }
        }
    }

    /// Spotlight が使えない・0 件だったときの本文検索。小さなテキストファイルだけを上限つきで読む。
    private static func findByContentScan(query: String, dirs: [URL], limit: Int) -> [Entry] {
        var entries: [Entry] = []
        var scanned = 0
        let deadline = Date().addingTimeInterval(contentScanTimeBudget)
        enumerate(dirs: dirs) { url in
            guard entries.count < limit,
                scanned < maxContentScannedFiles,
                Date() < deadline
            else { return .stop }
            // 名前が合っていれば本文を読まずに採用する。
            if url.lastPathComponent.localizedCaseInsensitiveContains(query) {
                entries.append(makeEntry(url))
                return .next
            }
            guard let data = head(of: url, upTo: maxContentBytesPerFile) else { return .next }
            scanned += 1
            guard let text = String(data: data, encoding: .utf8),
                text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            else { return .next }
            entries.append(makeEntry(url))
            return .next
        }
        return entries
    }

    /// 列挙の 1 件ごとの進め方。
    private enum Visit {
        /// 次の項目へ進む。
        case next
        /// これ以上は見ずに列挙を打ち切る。
        case stop
    }

    /// 許可ルートたちを深さ優先で舐める。隠しファイルは見ず、シンボリックリンク先は追わない。
    private static func enumerate(dirs: [URL], visit: (URL) -> Visit) {
        var visited = 0
        outer: for dir in dirs {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: dir,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )
            else { continue }
            for case let url as URL in enumerator {
                visited += 1
                if visited > maxVisitedEntries { break outer }
                guard
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                    values.isRegularFile == true
                else { continue }
                if visit(url) == .stop { break outer }
            }
        }
    }

    /// 先頭 `limit` バイトだけ読む。開けない・0 バイトなら nil。
    private static func head(of url: URL, upTo limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit), !data.isEmpty else { return nil }
        return data
    }

    /// URL から結果 1 件を組み立てる。
    private static func makeEntry(_ url: URL) -> Entry {
        let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .localizedTypeDescriptionKey, .typeIdentifierKey]
        )
        let kind =
            values?.localizedTypeDescription
            ?? values?.typeIdentifier
            ?? (url.pathExtension.isEmpty ? "file" : url.pathExtension)
        return Entry(
            name: url.lastPathComponent,
            path: url.path,
            kind: kind,
            size: Int64(values?.fileSize ?? 0)
        )
    }

    // MARK: - 取り込み

    /// `fetch_file` の本体。ポリシー通過済みのパスに対して先頭 `maxBytes` を読んで返す。
    public static func fetchFile(url: URL, maxBytes: Int) throws -> [String: Any] {
        let normalized = MacFileAccessPolicy.normalize(url)
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: normalized.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            throw MacFileSearchError.fileNotFound
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: normalized.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        guard let handle = try? FileHandle(forReadingFrom: normalized) else {
            throw MacFileSearchError.fileNotFound
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()

        return [
            "name": normalized.lastPathComponent,
            "path": normalized.path,
            "size": size,
            "truncated": size > Int64(data.count),
            "data_base64": data.base64EncodedString(),
        ]
    }
}
