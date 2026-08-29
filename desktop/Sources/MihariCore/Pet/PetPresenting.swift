import Foundation

/// ペットの監視まわりの見え方。監視を止めているあいだと休憩中はペットを静止させる。
public enum PetMonitoringMode: Sendable {
    /// 監視中。ふだんどおり動く。
    case watching
    /// 監視を止めている。
    case paused
    /// 休憩中。
    case onBreak
}

/// 検知エンジン（#9）とペット本体をつなぐ連携インターフェース。
///
/// 検知側はこの protocol の型だけを知っていればよく、ペットの中身を一切知らなくてよい。
@MainActor
public protocol PetPresenting: AnyObject {
    /// 検知エンジンからのイベントを受け取り、見た目（動き・吹き出し・問いかけ）に反映する。
    ///
    /// 連続で呼ばれた場合の扱い（セリフを溜めて順番に出す等）は実装側の責務とする。
    func present(_ event: PetEvent)

    /// デスクトップ常駐ウィンドウを表示する。
    func show()

    /// デスクトップ常駐ウィンドウを隠す。
    func hide()

    /// 出している問いかけを捨てて吹き出しを閉じる。首振りや無反応で検知側が問いかけを終えるときに呼ぶ。
    func dismissPrompt()

    /// 監視の状態を伝える。監視停止中・休憩中はペットを静止させる。
    func setMonitoring(_ mode: PetMonitoringMode)
}
