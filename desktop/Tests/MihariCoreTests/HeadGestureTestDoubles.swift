import Foundation

@testable import MihariCore

/// テスト用の `HeadOrientationSource`。CoreMotion を一切起動せず、
/// 指定した角度の時系列を指定した間隔で流す。
final class FakeHeadOrientationSource: HeadOrientationSource, @unchecked Sendable {

    private let availabilityValue: HeadGestureAvailability
    private let events: [(delaySeconds: TimeInterval, sample: HeadOrientationSample)]
    private let finishesStream: Bool

    /// - Parameters:
    ///   - availability: `availability()` が返す値。
    ///   - events: 流すサンプルと、直前のイベントからの待ち時間。
    ///   - finishesStream: 全イベントを流し終えたらストリームを終了するか。
    ///     `false` にすると、AirPods がつながったまま何も起きない状況を模せる。
    init(
        availability: HeadGestureAvailability = .available,
        events: [(delaySeconds: TimeInterval, sample: HeadOrientationSample)] = [],
        finishesStream: Bool = true
    ) {
        self.availabilityValue = availability
        self.events = events
        self.finishesStream = finishesStream
    }

    func availability() -> HeadGestureAvailability { availabilityValue }

    func updates() -> AsyncStream<HeadOrientationSample> {
        AsyncStream { continuation in
            let task = Task {
                for event in events {
                    if event.delaySeconds > 0 {
                        try? await Task.sleep(for: .seconds(event.delaySeconds))
                    }
                    if Task.isCancelled { break }
                    continuation.yield(event.sample)
                }
                if finishesStream {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
