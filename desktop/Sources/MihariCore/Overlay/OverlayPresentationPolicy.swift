import AppKit

/// オーバーレイ表示中に適用する `NSApplication.presentationOptions` を 1 箇所にまとめる。
///
/// `NSApplication.presentationOptions` は無効な組み合わせを代入すると
/// `NSInvalidArgumentException`(ObjC 例外)を投げ、Swift では catch できずアプリが即死する。
/// 選択式 UI は持たず常にこの固定値だけを使うことで、実行時に無効な組み合わせが
/// 生まれる余地そのものをなくしている。`invalidCombinationReasons` はその前提が崩れていないかを
/// 使う側(プレゼンター初期化時)と単体テストの両方で検証するための、副作用のない純粋関数。
public enum OverlayPresentationPolicy {

    /// 説教オーバーレイ表示中に適用する組み合わせ。
    /// Dock / メニューバーを隠し、Cmd+Tab によるアプリ切替を止める(Issue #17 の要求どおり)。
    ///
    /// `disableForceQuit` / `disableSessionTermination` も含める ―― Cmd+Option+Esc の
    /// 強制終了メニューと、ログアウト/再起動/シャットダウンの経路をこの間だけ塞ぐ。
    /// 唯一の脱出弁は `OverlayModel` の `hardDeadlineTask`(既定 90 秒、最大でも
    /// `durationRange` の上限 300 秒)で、途中で何が起きても必ずここまでに解除される。
    /// つまりこの封鎖が効いている時間には厳密な上限があり、無期限には続かない。
    public static let sermonOptions: NSApplication.PresentationOptions = [
        .hideDock,
        .hideMenuBar,
        .disableProcessSwitching,
        .disableForceQuit,
        .disableSessionTermination,
    ]

    /// 解除時に必ず戻す値。空集合は常に有効な組み合わせ。
    public static let dismissed: NSApplication.PresentationOptions = []

    /// Apple のドキュメント(`NSApplication.PresentationOptions` の Overview)が定める組み合わせ制約。
    /// 違反があれば理由の一覧を返す。空配列なら安全に代入できる。
    public static func invalidCombinationReasons(in options: NSApplication.PresentationOptions) -> [String] {
        var reasons: [String] = []

        if options.contains(.autoHideDock) && options.contains(.hideDock) {
            reasons.append("autoHideDock と hideDock は排他")
        }
        if options.contains(.autoHideMenuBar) && options.contains(.hideMenuBar) {
            reasons.append("autoHideMenuBar と hideMenuBar は排他")
        }
        if options.contains(.hideMenuBar) && !options.contains(.hideDock) {
            reasons.append("hideMenuBar には hideDock が必要")
        }

        let hasDockControl = options.contains(.hideDock) || options.contains(.autoHideDock)
        if options.contains(.autoHideMenuBar) && !hasDockControl {
            reasons.append("autoHideMenuBar には hideDock か autoHideDock のどちらかが必要")
        }
        let requiresDockControl: [(NSApplication.PresentationOptions, String)] = [
            (.disableProcessSwitching, "disableProcessSwitching"),
            (.disableForceQuit, "disableForceQuit"),
            (.disableSessionTermination, "disableSessionTermination"),
            (.disableMenuBarTransparency, "disableMenuBarTransparency"),
        ]
        for (option, name) in requiresDockControl where options.contains(option) && !hasDockControl {
            reasons.append("\(name) には hideDock か autoHideDock のどちらかが必要")
        }

        return reasons
    }
}
