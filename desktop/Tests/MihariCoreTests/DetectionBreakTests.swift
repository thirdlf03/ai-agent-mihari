import Foundation
import Testing

@testable import MihariCore

/// 休憩・監視停止・在席スタンプで「畳む」ところと、疑い 2 の問いかけの決着を見る。
@Suite("休憩と畳み方")
@MainActor
struct DetectionBreakTests {

    /// 疑い 2 まで進めて、問いかけが出た状態にする。
    @discardableResult
    private func advanceToPrompt(_ engine: DetectionEngine, base: Date) async -> Date {
        await engine.evaluate(now: base)
        await settle(until: { !engine.isCheckRunning })
        await engine.evaluate(now: base.addingTimeInterval(6))
        return base
    }

    // MARK: - 休憩

    @Test("休憩中は材料すら集めず、撮らないし喋らない")
    func breakSkipsEverything() async {
        let spy = ActionSpy()
        let pet = PetSpy()
        let engine = makeDetectionEngine(idle: IdleClock(600), spy: spy, pet: pet)
        let base = Date()

        engine.startBreak(now: base)
        let decision = await engine.evaluate(now: base.addingTimeInterval(1))

        #expect(decision.state == .normal)
        #expect(decision.reason.contains("休憩中"))
        #expect(engine.state == .normal)
        #expect(engine.lastSignals == nil)
        #expect(spy.presenceChecks.isEmpty)
        #expect(spy.macPhotos == 0)
        #expect(spy.posts.isEmpty)
    }

    @Test("休憩の始まりはペットに伝わる")
    func breakAnnouncesItself() async {
        let pet = PetSpy()
        let engine = makeDetectionEngine(idle: IdleClock(1), spy: ActionSpy(), pet: pet)

        engine.startBreak()

        #expect(pet.events.count == 1)
        #expect(pet.events.first?.state == .normal)
        #expect(pet.events.first?.line == "15 分だけ、待ってる。")
    }

    @Test("休憩が明けたら、次の tick で勝手に見張りへ戻る")
    func breakEndsOnItsOwn() async {
        let spy = ActionSpy()
        let engine = makeDetectionEngine(
            idle: IdleClock(600),
            spy: spy,
            thresholds: .quick(breakDurationSeconds: 10)
        )
        let base = Date()

        engine.startBreak(now: base)
        let decision = await engine.evaluate(now: base.addingTimeInterval(20))

        #expect(engine.breakUntil == nil)
        #expect(decision.state == .suspect(stage: 1))
        #expect(engine.log.contains { $0.reason.contains("休憩が明けた") })
    }

    @Test("疑いの途中で休憩に入ると、そこで畳んで Discord には何も送らない")
    func breakFoldsTheSuspicion() async {
        let spy = ActionSpy()
        let pet = PetSpy()
        let engine = makeDetectionEngine(idle: IdleClock(10), spy: spy, pet: pet)
        let base = Date()

        await advanceToPrompt(engine, base: base)
        #expect(engine.state == .suspect(stage: 2))

        engine.startBreak(now: base.addingTimeInterval(7))

        #expect(engine.state == .normal)
        #expect(pet.dismissals == 1)
        #expect(pet.returnSignals == 1)
        #expect(spy.posts.isEmpty)
    }

    @Test("監視を止めても休憩は残り、endBreak で消える")
    func stopKeepsTheBreak() async {
        let engine = makeDetectionEngine(idle: IdleClock(1), spy: ActionSpy())

        engine.startBreak()
        #expect(engine.breakUntil != nil)

        // 休憩と監視の開始 / 停止は別の話。止めたからといって休憩を取り消さない。
        engine.stop()
        #expect(engine.breakUntil != nil)

        engine.endBreak()
        #expect(engine.breakUntil == nil)
    }

    // MARK: - 監視の停止と在席スタンプ

    @Test("疑いの途中で監視を止めると、問いかけごと畳む")
    func stopFoldsTheEpisode() async {
        let spy = ActionSpy()
        let pet = PetSpy()
        let engine = makeDetectionEngine(idle: IdleClock(10), spy: spy, pet: pet)
        let base = Date()

        await advanceToPrompt(engine, base: base)
        engine.stop()

        #expect(engine.state == .normal)
        #expect(pet.dismissals == 1)
        #expect(pet.returnSignals == 1)
        #expect(spy.posts.isEmpty)
    }

    @Test("正常のまま監視を止めても、ペットには何も流れない")
    func stopWhileNormalSaysNothing() async {
        let pet = PetSpy()
        let engine = makeDetectionEngine(idle: IdleClock(0), spy: ActionSpy(), pet: pet)

        await engine.evaluate()
        #expect(engine.state == .normal)

        engine.stop()

        #expect(pet.events.isEmpty)
        #expect(pet.dismissals == 0)
    }

    @Test("Touch ID の途中で監視を止めると、ダイアログも閉じてもらう")
    func stopCancelsTheTouchIDCheck() async {
        let spy = ActionSpy()
        let engine = makeDetectionEngine(idle: IdleClock(10), spy: spy)

        await engine.evaluate()
        #expect(engine.isCheckRunning)

        engine.stop()

        #expect(engine.state == .normal)
        await settle(until: { spy.presenceCancels == 1 })
        #expect(spy.presenceCancels == 1)
    }

    @Test("在席スタンプを押されたら、疑いを畳んで正常に戻す")
    func stampFoldsTheSuspicion() async {
        let spy = ActionSpy()
        let pet = PetSpy()
        let engine = makeDetectionEngine(idle: IdleClock(10), spy: spy, pet: pet)
        let base = Date()

        await advanceToPrompt(engine, base: base)
        engine.acknowledgePresence()

        #expect(engine.state == .normal)
        #expect(pet.dismissals == 1)
        #expect(spy.posts.isEmpty)
    }

    @Test("正常のまま在席スタンプを押されても、ペットには何も流れない")
    func stampWhileNormalSaysNothing() async {
        let pet = PetSpy()
        let engine = makeDetectionEngine(idle: IdleClock(0), spy: ActionSpy(), pet: pet)

        engine.acknowledgePresence()

        #expect(pet.events.isEmpty)
    }

    // MARK: - 問いかけへの答え

    @Test("答えを採るのは先に来た 1 つだけ")
    func onlyTheFirstAnswerCounts() async throws {
        let spy = ActionSpy()
        let pet = PetSpy()
        let engine = makeDetectionEngine(idle: IdleClock(10), spy: spy, pet: pet)
        let base = Date()

        await advanceToPrompt(engine, base: base)
        let prompt = try #require(pet.prompts.first)

        prompt.onAnswer(false)
        await settle(until: { pet.dismissals == 1 })
        prompt.onAnswer(true)
        // 2 つ目が通っていれば正常に戻ってしまう。
        await settle(until: { engine.state == .normal })

        #expect(engine.state == .suspect(stage: 2))
        #expect(pet.dismissals == 1)
    }

    @Test("ボタンの「はい」でも正常に戻る")
    func buttonYesReturnsToNormal() async throws {
        let spy = ActionSpy()
        let pet = PetSpy()
        let engine = makeDetectionEngine(idle: IdleClock(10), spy: spy, pet: pet)
        let base = Date()

        await advanceToPrompt(engine, base: base)
        let prompt = try #require(pet.prompts.first)

        prompt.onAnswer(true)
        await settle(until: { engine.state == .normal })

        #expect(engine.state == .normal)
        #expect(pet.dismissals == 1)
    }

    @Test("AirPods が無いときは首振りの結果で何も起きず、問いかけは出たまま")
    func unavailableHeadGestureChangesNothing() async {
        let spy = ActionSpy()
        let pet = PetSpy()
        let engine = makeDetectionEngine(
            idle: IdleClock(10),
            spy: spy,
            pet: pet,
            headGesture: { _, _ in .unavailable(reason: "未接続") }
        )
        let base = Date()

        await advanceToPrompt(engine, base: base)
        // 決着しないことの確認なので、少しだけ回してから見る。
        await settle(until: { pet.dismissals > 0 })

        #expect(pet.dismissals == 0)
        #expect(pet.prompts.count == 1)
        #expect(engine.isCheckRunning)
    }

    @Test("問いかけには同封音声が添えられる")
    func promptCarriesItsAudio() async throws {
        let pet = PetSpy()
        let engine = makeDetectionEngine(idle: IdleClock(10), spy: ActionSpy(), pet: pet)

        await advanceToPrompt(engine, base: Date())
        let prompt = try #require(pet.prompts.first)

        #expect(prompt.audio == BundledVoiceLines.shared.audio(for: .askQuestion, text: prompt.question))
    }
}

@Suite("問いかけ 1 回分の状態")
@MainActor
struct SuspectPromptSessionTests {

    @Test("採用するのは最初の 1 回だけ")
    func claimOnce() {
        let session = SuspectPromptSession()

        #expect(session.isAwaitingAnswer)
        #expect(session.claim(sessionID: session.id))
        #expect(session.claim(sessionID: session.id) == false)
        #expect(session.isAwaitingAnswer == false)
    }

    @Test("別の問いかけ宛ての答えは通さない")
    func rejectsOtherSessions() {
        let session = SuspectPromptSession()
        let other = SuspectPromptSession()

        #expect(session.claim(sessionID: other.id) == false)
        // 弾いただけなので、本来の答えはまだ受け付けられる。
        #expect(session.claim(sessionID: session.id))
    }

    @Test("閉じたあとの答えは通さない")
    func settledSessionRejectsAnswers() {
        let session = SuspectPromptSession()

        session.settle()

        #expect(session.isAwaitingAnswer == false)
        #expect(session.claim(sessionID: session.id) == false)
    }
}
