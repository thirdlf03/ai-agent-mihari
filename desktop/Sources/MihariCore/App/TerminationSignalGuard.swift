import Dispatch

/// SIGTERM/SIGINT のデフォルト動作(即座にプロセスを落とす)を止め、代わりに渡された
/// コールバックを呼ぶ。
///
/// `kill <pid>` や Ctrl+C は既定では `applicationShouldTerminate` を経由せずに
/// アプリを即死させる。それでは `AppCoordinator.confirmQuit()` の確認をすり抜けてしまうため、
/// シグナルを一旦無視するよう切り替えたうえで `DispatchSourceSignal` で拾い直す。
///
/// `kill -9`(SIGKILL)はどのプロセスからも捕まえられない OS の制約であり、対象外。
/// これは実装の不備ではなく、Unix の仕様上そもそも防ぎようがない。
public final class TerminationSignalGuard: @unchecked Sendable {

    private var sources: [DispatchSourceSignal] = []
    private let signals: [Int32]
    private let onSignal: @Sendable () -> Void

    /// - Parameters:
    ///   - signals: 捕まえる対象。既定は SIGTERM と SIGINT。
    ///   - onSignal: 捕まえたときに呼ぶ処理。呼び出しは `.main` キューで行われる。
    public init(signals: [Int32] = [SIGTERM, SIGINT], onSignal: @escaping @Sendable () -> Void) {
        self.signals = signals
        self.onSignal = onSignal
    }

    /// 一度だけ呼ぶ。以後、このインスタンスが生きているあいだ対象シグナルを捕まえ続ける。
    public func install() {
        for sig in signals {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [onSignal] in onSignal() }
            source.resume()
            sources.append(source)
        }
    }
}
