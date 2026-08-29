import Foundation
import Testing

@testable import MihariCore

@Suite("首振りの問いかけ")
struct HeadGestureQuestionerTests {

    private func sample(_ t: TimeInterval, pitch: Double = 0, yaw: Double = 0) -> HeadOrientationSample {
        HeadOrientationSample(timestamp: t, pitchDegrees: pitch, yawDegrees: yaw)
    }

    @Test("AirPods未接続などで使えないときは待たずにスキップする")
    func skipsWhenUnavailable() async {
        let source = FakeHeadOrientationSource(availability: .unavailable(reason: "AirPodsが接続されていない"))
        let questioner = HeadGestureQuestioner(source: source)

        let response = await questioner.ask(prompt: "テスト", answerWindow: 5.0)

        guard case .unavailable(let reason) = response else {
            Issue.record("unavailable が返るはずが \(response) だった")
            return
        }
        #expect(reason == "AirPodsが接続されていない")
    }

    @Test("反応がなければ時間切れになる")
    func timesOutWithoutGesture() async {
        // AirPods はつながっているが、何も起きない状況を模す。ストリームは終了させない。
        let source = FakeHeadOrientationSource(events: [], finishesStream: false)
        let questioner = HeadGestureQuestioner(source: source)

        let response = await questioner.ask(prompt: "テスト", answerWindow: 0.05)

        #expect(response == .timedOut)
    }

    @Test("小さな動きが続くだけでは時間切れになる")
    func timesOutOnMinorMovementOnly() async {
        let events: [(TimeInterval, HeadOrientationSample)] = [
            (0.0, sample(0.0, pitch: 1)),
            (0.02, sample(0.02, pitch: -1)),
            (0.02, sample(0.04, pitch: 1)),
        ]
        let source = FakeHeadOrientationSource(
            events: events.map { (delaySeconds: $0.0, sample: $0.1) },
            finishesStream: false
        )
        let questioner = HeadGestureQuestioner(source: source)

        let response = await questioner.ask(prompt: "テスト", answerWindow: 0.1)

        #expect(response == .timedOut)
    }

    @Test("うなずきが来たら はい を返す")
    func answersYesOnNod() async {
        let events: [(TimeInterval, HeadOrientationSample)] = [
            (0.0, sample(0.0, pitch: 0)),
            (0.02, sample(0.2, pitch: -15)),
            (0.02, sample(0.4, pitch: 0)),
            (0.02, sample(0.6, pitch: -15)),
            (0.02, sample(0.8, pitch: 0)),
        ]
        let source = FakeHeadOrientationSource(events: events.map { (delaySeconds: $0.0, sample: $0.1) })
        let questioner = HeadGestureQuestioner(source: source)

        let response = await questioner.ask(prompt: "テスト", answerWindow: 5.0)

        #expect(response == .yes)
    }

    @Test("首振りが来たら いいえ を返す")
    func answersNoOnShake() async {
        let events: [(TimeInterval, HeadOrientationSample)] = [
            (0.0, sample(0.0, yaw: 0)),
            (0.02, sample(0.2, yaw: 20)),
            (0.02, sample(0.4, yaw: 0)),
            (0.02, sample(0.6, yaw: -20)),
            (0.02, sample(0.8, yaw: 0)),
        ]
        let source = FakeHeadOrientationSource(events: events.map { (delaySeconds: $0.0, sample: $0.1) })
        let questioner = HeadGestureQuestioner(source: source)

        let response = await questioner.ask(prompt: "テスト", answerWindow: 5.0)

        #expect(response == .no)
    }
}
