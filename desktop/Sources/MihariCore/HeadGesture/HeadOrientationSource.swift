import Foundation

/// 頭の向きのサンプルを供給する側の契約。
///
/// `HeadGestureQuestioner` と `HeadGestureController` はこのプロトコルだけに依存する。
/// 本物の実装は `AirPodsHeadOrientationSource`。テストは CoreMotion を起動しないフェイクを使う。
public protocol HeadOrientationSource: Sendable {

    /// 現在の接続状況・対応状況を調べる。プロンプトは出さない。
    func availability() -> HeadGestureAvailability

    /// 更新の購読を始める。呼ぶたびに新しい購読を張るため、同時に複数回呼ばないこと。
    /// 返した `AsyncStream` が終了(キャンセルを含む)したら、内部の購読も止める。
    func updates() -> AsyncStream<HeadOrientationSample>
}
