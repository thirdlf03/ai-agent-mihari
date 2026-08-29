import Foundation

/// 検知エンジン（#9）とペット本体をつなぐ連携インターフェース。
///
/// 検知側はこの protocol の型だけを知っていればよく、ペットの中身（暫定の画像1枚 or
/// 本実装のアニメーション）を一切知らなくてよい。本実装が来たら、この protocol に適合する
/// 新しい型（例: `LivePetPresenter`）を用意して差し替えるだけで済む。
/// 差し替え手順の詳細は `desktop/README.md` の「ペット連携インターフェース」を参照。
@MainActor
public protocol PetPresenting: AnyObject {
    /// 検知エンジンからのイベントを受け取り、見た目（画像・吹き出し・問いかけ）に反映する。
    ///
    /// 連続で呼ばれた場合の扱い（セリフを溜めて順番に出す等）は実装側の責務とする。
    func present(_ event: PetEvent)

    /// デスクトップ常駐ウィンドウを表示する。
    func show()

    /// デスクトップ常駐ウィンドウを隠す。監視を止めたときなどに呼ぶ。
    func hide()
}
