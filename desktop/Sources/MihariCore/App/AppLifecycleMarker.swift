import Foundation

/// 前回のセッションが正常に終了できたかを、プロセスをまたいで覚えておく。
///
/// `kill -9` はプロセスに何も実行させる隙を与えないため、「殺された」ことを
/// 死ぬ側から記録することはできない。代わりに「まだ正常終了していない」フラグを
/// セッション開始時に立て、正常終了の直前(`confirmQuit` が認証を通したとき)にだけ
/// 消す、という dirty フラグ方式にしてある。次に起動したときフラグが立ったままなら、
/// 前回は(kill だろうと crash だろうと)正常には終わらなかったと分かる。
public protocol AppLifecycleMarking {
    /// 前回、正常に終了できていたか。まだ一度もセッションを記録していなければ true
    /// (初めての起動でいきなり怒らせないため)。
    func wasPreviousSessionGraceful() -> Bool
    /// このセッションが始まった(まだ正常終了していない)ことを記録する。
    func markSessionStarted()
    /// 正常に終了する直前に呼ぶ。
    func markGracefulShutdown()
}

/// `UserDefaults` に真偽値を 1 つ持つだけの実装。
public struct UserDefaultsLifecycleMarker: AppLifecycleMarking {
    static let key = "com.thirdlf03.mihari.sessionEndedGracefully"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func wasPreviousSessionGraceful() -> Bool {
        // キーが無い(初回起動)なら true 扱いにして、いきなり怒らせない。
        defaults.object(forKey: Self.key) == nil || defaults.bool(forKey: Self.key)
    }

    public func markSessionStarted() {
        defaults.set(false, forKey: Self.key)
    }

    public func markGracefulShutdown() {
        defaults.set(true, forKey: Self.key)
    }
}
