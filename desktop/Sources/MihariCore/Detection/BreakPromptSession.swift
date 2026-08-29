import Foundation

/// 「休憩中?」の問いかけ 1 回分の状態。
///
/// 回答は 3 か所から来る。ペットのボタン・AirPods の首振り・無反応タイマー。
/// **採用するのは先に来た 1 つだけ。** 2 つ目以降は捨て、待っているタスクは畳む。
/// 二重に休憩へ入ったり、閉じたあとの返事で休憩が始まったりしないための番人。
///
/// セッション ID を持たせてあるのは、閉じたあとに飛んでくる古い回答を弾くため。
/// 問いかけを出し直したあとに前回の首振りが届いても、ID が違うので通らない。
@MainActor
final class BreakPromptSession {

    /// タイマーの待ち方。本番は `Task.sleep`、テストでは短時間で解決するものに差し替える。
    typealias Sleeping = (Duration) async -> Void

    /// この問いかけの識別子。回答に添えてもらい、一致したものだけを受け付ける。
    let id = UUID()

    private var isSettled = false
    private var waiters: [Task<Void, Never>] = []

    /// まだ回答を待っているか。
    var isAwaitingAnswer: Bool { !isSettled }

    /// この回答を採用してよいか。**通るのは最初の 1 回だけ。**
    ///
    /// - Parameter sessionID: 回答に添えられた識別子。別の問いかけ宛てなら弾く。
    /// - Returns: 採用してよければ `true`。以後は何を渡しても `false`。
    func claim(sessionID: UUID) -> Bool {
        guard !isSettled, sessionID == id else { return false }
        isSettled = true
        return true
    }

    /// AirPods の首振りを待つ。
    ///
    /// `.yes` / `.no` だけを回答として扱う。`.timedOut` / `.unavailable` は無視する
    /// ——AirPods が無いことを「いいえ」と読み替える理由がないし、時間切れは
    /// `startTimeout(seconds:sleep:onTimeout:)` 側が面倒を見る。
    func waitForHeadGesture(
        question: String,
        timeout: TimeInterval,
        ask: @escaping @Sendable (String, TimeInterval) async -> HeadGestureResponse,
        onAnswer: @escaping (UUID, Bool) -> Void
    ) {
        let id = self.id
        track(
            Task {
                let response = await ask(question, timeout)
                guard !Task.isCancelled else { return }
                switch response {
                case .yes: onAnswer(id, true)
                case .no: onAnswer(id, false)
                case .timedOut, .unavailable: return
                }
            }
        )
    }

    /// 無反応のタイマーを張る。返事が無いまま時間が過ぎたら問いかけを閉じる。
    func startTimeout(
        seconds: TimeInterval,
        sleep: @escaping Sleeping,
        onTimeout: @escaping (UUID) -> Void
    ) {
        let id = self.id
        track(
            Task {
                await sleep(.seconds(seconds))
                guard !Task.isCancelled else { return }
                onTimeout(id)
            }
        )
    }

    /// 決着させる。以後の回答を受け付けず、待っているタスクも畳む。
    /// 回答が決まったときにも、エピソードが終わって問いかけごと消すときにも呼ぶ。
    func settle() {
        isSettled = true
        for waiter in waiters { waiter.cancel() }
        waiters.removeAll()
    }

    private func track(_ task: Task<Void, Never>) {
        guard !isSettled else {
            task.cancel()
            return
        }
        waiters.append(task)
    }
}
