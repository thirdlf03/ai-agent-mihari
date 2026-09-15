import AppKit
import Foundation
import os

/// `hand_off_file` を依頼（job）ごとのフォルダへ束ねるステージ。
///
/// 届いたファイルは短い窓でまとめてから `stageRoot/<jobID>/` へ
/// 原本のシンボリックリンクを並べ、そのフォルダを Finder で開き、
/// カットインは1回だけ出す。同じ jobID の手渡しは窓を跨いでも
/// 常に同じフォルダへ入り、フォルダが増え続けることはない。
public final class MacHandoffStage: @unchecked Sendable {

    /// 手渡し 1 件ぶん。`key` は束ねる単位（jobID）。`label` は op 由来の帯の文言。
    public struct Entry: Sendable {
        public let url: URL
        public let label: String?
        public let key: String

        public init(url: URL, label: String?, key: String) {
            self.url = url
            self.label = label
            self.key = key
        }
    }

    /// 1 キーぶんの結果。`directory` は開いたフォルダ（失敗時は nil）。
    public struct Outcome: Sendable {
        public let directory: URL?
        public let presented: Bool
        public let error: String?
    }

    /// 既定の置き場所。`~/Mihari/handoffs/<jobID>/` を依頼ごとに作る。
    public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Mihari")
        .appendingPathComponent("handoffs")

    private let stageRoot: URL
    /// 束ねる窓(秒)。最初の1件の到着からこの時間で締め切る。
    private let window: TimeInterval
    /// フォルダを Finder で開く口。テストでは記録用スタブに差し替える。
    private let openFolder: @Sendable (URL) -> Void

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// 出し手。`CGEventMacControlOperator.handoffPresenter` が後から差し込む。
    public var presenter: (any MacFileHandoffPresenting)? {
        get { state.withLock { $0.presenter } }
        set { state.withLock { $0.presenter = newValue } }
    }

    struct State {
        var pending: [Entry] = []
        var flushTask: Task<[String: Outcome], Never>?
        /// key（jobID）→ 割り当て済みフォルダ。同一依頼の手渡しを1フォルダに維持する。
        var directories: [String: URL] = [:]
        public var presenter: (any MacFileHandoffPresenting)?
    }

    public init(
        stageRoot: URL = MacHandoffStage.defaultRoot,
        window: TimeInterval = 1.0,
        openFolder: @escaping @Sendable (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.stageRoot = stageRoot
        self.window = window
        self.openFolder = openFolder
    }

    /// 1 件を今のバッチへ積む。戻り値はバッチ全員で共有する flush の Task。
    /// 呼び出し側は `key` で自分ぶんの Outcome を取り出す。
    @discardableResult
    public func add(_ entry: Entry) -> Task<[String: Outcome], Never> {
        state.withLock { state in
            state.pending.append(entry)
            if let task = state.flushTask {
                return task
            }
            let task = Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.window ?? 0))
                guard let self else {
                    return [entry.key: Outcome(directory: nil, presented: false, error: "stage released")]
                }
                return await self.flush()
            }
            state.flushTask = task
            return task
        }
    }

    private func flush() async -> [String: Outcome] {
        let (entries, presenter) = state.withLock {
            state -> ([Entry], (any MacFileHandoffPresenting)?) in
            let entries = state.pending
            state.pending = []
            state.flushTask = nil
            return (entries, state.presenter)
        }
        // キー（jobID）ごとに分け、依頼単位で1フォルダ・1演出にする。
        var order: [String] = []
        var grouped: [String: [Entry]] = [:]
        for entry in entries {
            if grouped[entry.key] == nil { order.append(entry.key) }
            grouped[entry.key, default: []].append(entry)
        }
        var outcomes: [String: Outcome] = [:]
        for key in order {
            outcomes[key] = await flushKey(key, entries: grouped[key] ?? [], presenter: presenter)
        }
        return outcomes
    }

    private func flushKey(
        _ key: String,
        entries: [Entry],
        presenter: (any MacFileHandoffPresenting)?
    ) async -> Outcome {
        do {
            let dir = try directory(for: key)
            for entry in entries {
                try link(entry.url, into: dir)
            }
            openFolder(dir)
            // 複数件は件数を帯に出す。1件なら指定 label（無ければファイル名）を維持する。
            let label =
                if entries.count > 1 {
                    "\(entries.count)件のファイル"
                } else {
                    entries[0].label ?? entries[0].url.lastPathComponent
                }
            let presented = await presenter?.presentFile(at: dir, label: label) ?? false
            return Outcome(directory: dir, presented: presented, error: nil)
        } catch {
            return Outcome(directory: nil, presented: false, error: error.localizedDescription)
        }
    }

    /// key（jobID）に対応するフォルダ。既にあればそれを使い回す。
    private func directory(for key: String) throws -> URL {
        if let dir = state.withLock({ $0.directories[key] }) {
            return dir
        }
        let dir = stageRoot.appendingPathComponent(Self.sanitize(key))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        state.withLock { $0.directories[key] = dir }
        return dir
    }

    /// フォルダ名に使えない文字を `_` へ。空キーは misc 扱い。
    private static func sanitize(_ key: String) -> String {
        let cleaned = key.map { $0 == "/" || $0 == ":" ? "_" : $0 }
        let name = String(cleaned).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "misc" : name
    }

    /// 原本へのシンボリックリンクを `dir` 内へ作る。同名は ` (2)` などで避け、
    /// 同じ原本へのリンクが既にあれば再利用する。
    private func link(_ url: URL, into dir: URL) throws {
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var index = 1
        while true {
            let name =
                index == 1
                ? url.lastPathComponent
                : (ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)")
            let candidate = dir.appendingPathComponent(name)
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path) {
                // 既存リンクが同じ原本を指すなら再利用。違う原本なら別名へ。
                if dest == url.path { return }
            } else if !FileManager.default.fileExists(atPath: candidate.path) {
                try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: url)
                return
            }
            index += 1
        }
    }
}
