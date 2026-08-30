import Foundation
import Testing

@testable import MihariCore

/// 遷移表を頭から終わりまで 1 本で通す。個々の分岐は他のテストが押さえているので、
/// ここは「正常 → 疑い 1 → 2 → 3 → 晒し → メンヘラ → 戻る」が繋がっているかだけを見る。
@Suite("監視ループ")
@MainActor
struct DetectionSmokeTests {

    @Test("放置し続けると晒しまで進み、戻ってくると締めて正常に返る")
    func fullWalkthrough() async throws {
        let spy = ActionSpy()
        spy.presenceOutcome = .timedOut
        let pet = PetSpy()
        let idle = IdleClock(1)
        let engine = makeDetectionEngine(
            idle: idle,
            spy: spy,
            pet: pet,
            thresholds: .quick(
                suspectSeconds: 10,
                stageIntervalSeconds: 5,
                clingyIntervalSeconds: 20,
                clingyEvidenceIntervalSeconds: 100
            ),
            // 問いかけの返事を待たずに時間切れへ倒す。
            sleep: { _ in }
        )
        let base = Date()

        // 正常。
        #expect(await engine.evaluate(now: base).state == .normal)

        // 疑い 1。すぐ Touch ID を確かめ、指が置かれないまま時間切れになる。
        idle.set(600)
        #expect(await engine.evaluate(now: base.addingTimeInterval(1)).state == .suspect(stage: 1))
        await settle(until: { !engine.isCheckRunning })
        #expect(spy.presenceChecks.count == 1)

        // 疑い 2。問いかけを出し、返事が無いまま時間切れになる。
        #expect(await engine.evaluate(now: base.addingTimeInterval(7)).state == .suspect(stage: 2))
        await settle(until: { !engine.isCheckRunning })
        #expect(pet.prompts.count == 1)
        #expect(pet.dismissals == 1)

        // 疑い 3。最終警告だけ。
        #expect(await engine.evaluate(now: base.addingTimeInterval(13)).state == .suspect(stage: 3))
        #expect(spy.posts.isEmpty)

        // 晒し。証拠を撮って送り、そのままメンヘラモードへ。
        let exposure = await engine.evaluate(now: base.addingTimeInterval(19))
        #expect(exposure.state == .exposing)
        #expect(spy.macPhotos == 1)
        #expect(spy.posts.count == 1)
        if case .clingy = engine.state {} else { Issue.record("メンヘラモードに入っていない") }

        // メンヘラモード。間隔ごとにテキストだけ投げ続ける。
        await engine.evaluate(now: base.addingTimeInterval(40))
        #expect(spy.posts.count == 2)
        #expect(spy.posts.last?.image == nil)

        // 戻ってきた。メンションなしで 1 件だけ送って正常に返る。
        idle.set(0)
        #expect(await engine.evaluate(now: base.addingTimeInterval(45)).state == .normal)
        #expect(spy.posts.count == 3)
        #expect(spy.posts.last?.mention == false)
        #expect(engine.state == .normal)
        #expect(engine.escalationStage == 0)

        // ペットに渡した段階も 1 → 2 → 3 → 4 → 5 と上がっている。
        let stages = pet.events.map(\.escalationStage)
        #expect(stages.first == 1)
        #expect(stages.contains(2))
        #expect(stages.contains(3))
        #expect(stages.contains(PetEvent.exposingStage))
        #expect(stages.contains(PetEvent.clingyStage))
        #expect(stages.last == 0)
    }

    @Test("監視を始めると、ループが自分で評価して疑いに入る")
    func loopRunsOnItsOwn() async {
        let spy = ActionSpy()
        let engine = makeDetectionEngine(idle: IdleClock(600), spy: spy)

        engine.start()
        await settle(until: { engine.state == .suspect(stage: 1) })

        #expect(engine.isWatching)
        #expect(engine.state == .suspect(stage: 1))

        engine.stop()
        #expect(engine.isWatching == false)
        #expect(engine.state == .normal)
    }
}
