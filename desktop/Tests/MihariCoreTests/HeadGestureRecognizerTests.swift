import Foundation
import Testing

@testable import MihariCore

@Suite("首振りジェスチャの判定")
struct HeadGestureRecognizerTests {

    private func sample(_ t: TimeInterval, pitch: Double = 0, yaw: Double = 0) -> HeadOrientationSample {
        HeadOrientationSample(timestamp: t, pitchDegrees: pitch, yawDegrees: yaw)
    }

    private func decisions(_ samples: [HeadOrientationSample]) -> [HeadGestureRecognizer.Decision] {
        var recognizer = HeadGestureRecognizer()
        return samples.map { recognizer.ingest($0) }
    }

    @Test("うなずきを「はい」と判定する")
    func nodIsYes() {
        let samples = [
            sample(0.0, pitch: 0),
            sample(0.2, pitch: -15),
            sample(0.4, pitch: 0),
            sample(0.6, pitch: -15),
            sample(0.8, pitch: 0),
        ]

        #expect(decisions(samples).last == .yes)
    }

    @Test("横に振ると「いいえ」と判定する")
    func shakeIsNo() {
        let samples = [
            sample(0.0, yaw: 0),
            sample(0.2, yaw: 20),
            sample(0.4, yaw: 0),
            sample(0.6, yaw: -20),
            sample(0.8, yaw: 0),
        ]

        #expect(decisions(samples).last == .no)
    }

    @Test("ゆっくりした自然な首の動き(反転1回だけ)は誤検知しない")
    func slowNaturalMovementIsIgnored() {
        // 画面を見るために、ゆっくり下を向いてからゆっくり戻すだけの動き。振幅は大きいが反転は1回だけ。
        let samples = [
            sample(0.0, pitch: 0),
            sample(0.4, pitch: -10),
            sample(0.7, pitch: -20),
            sample(1.0, pitch: -10),
            sample(1.3, pitch: 0),
        ]

        #expect(decisions(samples).allSatisfy { $0 == .none })
    }

    @Test("振幅が小さすぎるものは拾わない")
    func tooSmallAmplitudeIsIgnored() {
        let samples = [
            sample(0.0, pitch: 0),
            sample(0.2, pitch: -5),
            sample(0.4, pitch: 0),
            sample(0.6, pitch: -5),
            sample(0.8, pitch: 0),
        ]

        #expect(decisions(samples).allSatisfy { $0 == .none })
    }

    @Test("時間窓を外れた往復はまとめて数えない")
    func reversalsOutsideWindowAreNotCombined() {
        // 1回目の往復(0.0〜0.4秒)と2回目の往復(5.0〜5.4秒)は5秒近く離れており、
        // 既定の時間窓(1.6秒)には同時に収まらない。それぞれ単独では反転1回分でしかない。
        let samples = [
            sample(0.0, pitch: 0),
            sample(0.2, pitch: -15),
            sample(0.4, pitch: 0),
            sample(5.0, pitch: 0),
            sample(5.2, pitch: -15),
            sample(5.4, pitch: 0),
        ]

        #expect(decisions(samples).allSatisfy { $0 == .none })
    }

    @Test("斜めの動きで両軸とも閾値を超えたときは判定を保留する")
    func diagonalMovementIsHeldBack() {
        let samples = [
            sample(0.0, pitch: 0, yaw: 0),
            sample(0.2, pitch: -15, yaw: 15),
            sample(0.4, pitch: 0, yaw: 0),
            sample(0.6, pitch: -15, yaw: 15),
            sample(0.8, pitch: 0, yaw: 0),
        ]

        #expect(decisions(samples).allSatisfy { $0 == .none })
    }

    @Test("閾値は注入でき、厳しくすれば同じ動きでも反応しなくなる")
    func thresholdsAreInjectable() {
        let strict = HeadGestureThresholds(
            minAmplitudeDegrees: 100,
            minReversalCount: 2,
            timeWindowSeconds: 1.6,
            noiseFloorDegrees: 1.5,
            maxCrossAxisRatio: 0.6
        )
        var recognizer = HeadGestureRecognizer(thresholds: strict)
        let samples = [
            sample(0.0, pitch: 0),
            sample(0.2, pitch: -15),
            sample(0.4, pitch: 0),
            sample(0.6, pitch: -15),
            sample(0.8, pitch: 0),
        ]

        let results = samples.map { recognizer.ingest($0) }
        #expect(results.allSatisfy { $0 == .none })
    }
}
