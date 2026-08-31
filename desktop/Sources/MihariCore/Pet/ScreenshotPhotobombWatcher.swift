import Foundation
import os

/// スクリーンショットが保存されたのを見張る。
///
/// 保存先フォルダもファイル名もユーザーが変えられる(`defaults write com.apple.screencapture`、
/// ロケールで「スクリーンショット…」/「Screen Shot…」)ので、名前やパスでは当てにいかない。
/// Spotlight のメタデータ `kMDItemIsScreenCapture` はスクショにだけ付くので、それだけを見る。
@MainActor
public final class ScreenshotPhotobombWatcher {

    // 通知ハンドラ(Sendable クロージャ)からも書くので、アクタから外しておく。
    nonisolated private static let logger = Logger(
        subsystem: "com.thirdlf03.mihari",
        category: "photobomb"
    )

    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private var handler: ((URL) -> Void)?
    /// 見張り始めた時刻。これより古いスクショは「前からあったもの」として触らない。
    private var startedAt = Date()
    /// もう合成したパス。合成すると自分でファイルを書き換えるので、二度と拾わないようにする。
    private var handledPaths: Set<String> = []

    public init() {}

    /// 見張り始める。すでに見張っていれば何もしない。
    ///
    /// - Parameter onScreenshot: 新しく保存されたスクショのファイル URL。メインスレッドで呼ばれる。
    public func start(onScreenshot: @escaping (URL) -> Void) {
        guard handler == nil else { return }
        handler = onScreenshot
        startedAt = Date()
        handledPaths.removeAll()

        // Spotlight の結果は TCC で絞られる。スクショの保存先(既定は ~/Desktop)への
        // アクセスを許可されていないと、クエリはそのフォルダのスクショを 1 件も返さない
        // ―― 通知が来ないだけで、エラーも空振りの気配も出ない。先に保存先を 1 度読んで
        // 許可を促しておく。許可が下りれば、走っているクエリがそのまま拾い始めるので
        // 貼り直しは要らない。
        requestAccessToScreenshotFolder()

        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        query.searchScopes = [NSMetadataQueryUserHomeScope]

        // 集め終わった時点の結果は「前からあったスクショ」なので全部捨てる。
        // 件数だけ残しておく ―― 保存先のぶんが 0 件なら、そのフォルダが見えていない。
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: query,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.logGatheringResult()
                }
            }
        )
        // 増えた分(added)と、変わった分(changed)の両方を見る。Spotlight が先に
        // 属性なしでインデックスして、あとから `kMDItemIsScreenCapture` が付いたときは
        // changed でしか届かない。自分の上書きによる changed は `handledPaths` で弾く。
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidUpdate,
                object: query,
                queue: .main
            ) { [weak self] notification in
                // `Notification` はアクタを越えて渡せないので、要る値だけここで抜き出す。
                let info = notification.userInfo
                let added = (info?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem]) ?? []
                let changed =
                    (info?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem]) ?? []
                let candidates =
                    added.compactMap { ScreenshotCandidate(item: $0, arrival: .added) }
                    + changed.compactMap { ScreenshotCandidate(item: $0, arrival: .changed) }
                MainActor.assumeIsolated {
                    self?.handle(candidates)
                }
            }
        )

        guard query.start() else {
            Self.logger.notice("Spotlight の検索を始められないので、スクショへの写り込みはやらない")
            stop()
            return
        }
        Self.logger.notice("スクショの見張りを始めた")
    }

    /// 見張るのをやめる。
    public func stop() {
        query.stop()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        handler = nil
    }

    /// スクショの保存先を 1 度読んで、TCC の許可を促す。
    ///
    /// 許可のダイアログはユーザーが答えるまで戻ってこないので、メインスレッドから外して呼ぶ。
    /// 写り込みは余興なので、断られてもログを残すだけで何もしない。
    private func requestAccessToScreenshotFolder() {
        let folder = Self.screenshotFolder()
        Task.detached(priority: .utility) {
            do {
                let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                Self.logger.notice(
                    "スクショの保存先を読めた: \(folder.path, privacy: .public) (\(entries.count, privacy: .public) 件)"
                )
            } catch {
                Self.logger.notice(
                    """
                    スクショの保存先を読めないので写り込みは効かない(ファイルとフォルダの許可が要る): \
                    \(folder.path, privacy: .public) \(error.localizedDescription, privacy: .public)
                    """
                )
            }
        }
    }

    /// スクショの保存先。`defaults write com.apple.screencapture location` で変えられる。
    /// 設定が無ければ既定のデスクトップ。
    private static func screenshotFolder() -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        guard
            let location = UserDefaults(suiteName: "com.apple.screencapture")?
                .string(forKey: "location"),
            !location.isEmpty
        else {
            return home.appendingPathComponent("Desktop", isDirectory: true)
        }
        return URL(
            fileURLWithPath: (location as NSString).expandingTildeInPath,
            isDirectory: true
        )
    }

    /// 集め終わった時点の件数を残す。保存先のぶんが 0 件なら、そのフォルダが
    /// TCC で見えていない ―― この先いくらスクショを撮っても通知は来ない。
    private func logGatheringResult() {
        let folderPath = Self.screenshotFolder().standardizedFileURL.path
        query.disableUpdates()
        defer { query.enableUpdates() }

        var inFolder = 0
        for index in 0..<query.resultCount {
            guard let item = query.result(at: index) as? NSMetadataItem,
                let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            if path.hasPrefix(folderPath + "/") { inFolder += 1 }
        }
        Self.logger.notice(
            """
            既存のスクショは無視して、これから増える分だけ見張る \
            (Spotlight から見えている既存 \(self.query.resultCount, privacy: .public) 件、\
            うち保存先 \(inFolder, privacy: .public) 件)
            """
        )
    }

    /// 届いた分をまとめて処理する。前からあったものと、もう合成したものは触らない。
    private func handle(_ candidates: [ScreenshotCandidate]) {
        for candidate in candidates {
            let name = (candidate.path as NSString).lastPathComponent
            // 保険その 1。見張り始めるより前に撮られたものは、届いても触らない。
            if let created = candidate.createdAt, created < startedAt {
                Self.logger.notice(
                    "見張る前のスクショなので触らない(\(candidate.arrival.label, privacy: .public)): \(name, privacy: .public)"
                )
                continue
            }
            // 保険その 2。同じパスは二度と処理しない(自分の上書きも changed で戻ってくる)。
            guard handledPaths.insert(candidate.path).inserted else {
                Self.logger.notice(
                    "もう写り込んだスクショなので触らない(\(candidate.arrival.label, privacy: .public)): \(name, privacy: .public)"
                )
                continue
            }
            Self.logger.notice(
                "新しいスクショを見つけた(\(candidate.arrival.label, privacy: .public)): \(name, privacy: .public)"
            )
            handler?(URL(fileURLWithPath: candidate.path))
        }
    }
}

/// 更新通知から抜き出した、スクショ 1 件分の見たい値。
private struct ScreenshotCandidate: Sendable {
    /// どの経路で届いたか。実機のログで見分けるためだけに持つ。
    enum Arrival: Sendable {
        case added
        case changed

        var label: String {
            switch self {
            case .added: return "追加"
            case .changed: return "変更"
            }
        }
    }

    let path: String
    let createdAt: Date?
    let arrival: Arrival

    init?(item: NSMetadataItem, arrival: Arrival) {
        guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else {
            return nil
        }
        self.path = path
        self.createdAt = item.value(forAttribute: NSMetadataItemContentCreationDateKey) as? Date
        self.arrival = arrival
    }
}
