import Foundation
import os

/// 「質問を出す → 一定時間内に首振りを待つ → はい/いいえ/時間切れ を返す」を1つの async API にまとめる。
///
/// ペットの問いかけ UI(#16)は、この型だけを見て呼び出せばよい。CoreMotion にも SwiftUI にも
/// 依存しないため、UI の実装が固まる前でも単体テストできる。
public final class HeadGestureQuestioner: Sendable {

    /// 首振りを待つ既定の時間。この間に判定できる動きがなければ `.timedOut` を返す。
    public static let defaultAnswerWindow: TimeInterval = 6.0

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "head-gesture")

    private let source: HeadOrientationSource
    private let thresholds: HeadGestureThresholds

    public init(
        source: HeadOrientationSource = AirPodsHeadOrientationSource(),
        thresholds: HeadGestureThresholds = .default
    ) {
        self.source = source
        self.thresholds = thresholds
    }

    /// 質問を出し、`answerWindow` 秒だけ首振りを待って結果を返す。
    ///
    /// AirPods が未接続 / 非対応機種 / 権限なしのときは、待たずに `.unavailable` を返して
    /// 質問自体をスキップする。
    ///
    /// - Parameter prompt: ログに残すだけの、質問内容の説明。判定には使わない。
    public func ask(
        prompt: String,
        answerWindow: TimeInterval = HeadGestureQuestioner.defaultAnswerWindow
    ) async -> HeadGestureResponse {
        let availability = source.availability()
        guard availability.isAvailable else {
            let reason = availability.reason ?? "不明な理由で利用できない"
            Self.logger.info("質問をスキップ: \(prompt, privacy: .public) 理由=\(reason, privacy: .public)")
            return .unavailable(reason: reason)
        }

        Self.logger.info("質問を開始: \(prompt, privacy: .public) window=\(answerWindow, privacy: .public)秒")
        let response = await waitForAnswer(answerWindow: answerWindow)
        Self.logger.info("質問が終了: \(prompt, privacy: .public) 結果=\(String(describing: response), privacy: .public)")
        return response
    }

    /// サンプルの購読と時間切れタイマーを競走させ、先に決着した方を結果として返す。
    /// 決着後は必ず双方のタスクをキャンセルし、`source` 側の購読(≒バッテリー消費)を止める。
    private func waitForAnswer(answerWindow: TimeInterval) async -> HeadGestureResponse {
        let source = self.source
        let thresholds = self.thresholds

        return await withTaskGroup(of: HeadGestureResponse?.self) { group in
            group.addTask {
                var recognizer = HeadGestureRecognizer(thresholds: thresholds)
                for await sample in source.updates() {
                    switch recognizer.ingest(sample) {
                    case .yes: return .yes
                    case .no: return .no
                    case .none: continue
                    }
                }
                // 購読がキャンセルや切断で先に終わった場合。時間切れタスク側の結果を待つ。
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(answerWindow))
                return .timedOut
            }

            var result: HeadGestureResponse = .timedOut
            for await outcome in group {
                if let outcome {
                    result = outcome
                    break
                }
            }
            group.cancelAll()
            return result
        }
    }
}
