import Foundation
import Testing

@testable import MihariCore

/// 無操作秒数を外から動かせる箱。`@Sendable` クロージャから読むのでロックで守る。
private final class IdleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    init(_ seconds: TimeInterval = 0) { value = seconds }

    func set(_ seconds: TimeInterval) { lock.withLock { value = seconds } }
    func read() -> TimeInterval { lock.withLock { value } }
}

/// ペットに届いたイベントと、問いかけを引っ込めた回数を溜める箱。
private final class PetSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [PetEvent] = []
    private var _dismissals = 0

    var events: [PetEvent] { lock.withLock { _events } }
    var dismissals: Int { lock.withLock { _dismissals } }
    /// 問いかけの付いたイベントだけ。
    var prompts: [PetYesNoPrompt] { events.compactMap(\.prompt) }
    /// セリフの無い正常イベント(＝「おかえり」の合図)の数。
    var returnSignals: Int { events.filter { $0.state == .normal && $0.line.isEmpty }.count }

    func record(_ event: PetEvent) { lock.withLock { _events.append(event) } }
    func recordDismissal() { lock.withLock { _dismissals += 1 } }
}

/// 音楽は鳴っていない、で固定する。AppleScript を実際に投げさせない。
private struct SilentMusic: MusicControlling {
    func nowPlaying() async -> NowPlaying { .silent }
    func stopPlaying() async -> MusicStopOutcome { .nothingWasPlaying }
    func resumePlaying(_ outcome: MusicStopOutcome) async {}
}

@Suite("休憩と問いかけ")
@MainActor
struct DetectionBreakTests {

    /// テスト用の閾値。カメラを開ける秒数は十分大きくして、視線監視を走らせない。
    private func thresholds(
        breakDurationSeconds: TimeInterval = 900,
        promptTimeoutSeconds: TimeInterval = 100
    ) -> DetectionThresholds {
        DetectionThresholds(
            suspectSeconds: 1,
            confirmSeconds: 3,
            gazeWatchSeconds: 1000,
            notLookingDurationSeconds: 1000,
            gazeFreshnessSeconds: 10,
            stampGraceSeconds: 0,
            cooldownSeconds: 1000,
            breakDurationSeconds: breakDurationSeconds,
            promptTimeoutSeconds: promptTimeoutSeconds
        )
    }

    private func engine(
        idle: IdleClock,
        spy: ActionSpy,
        pet: PetSpy,
        thresholds: DetectionThresholds,
        headGesture: @escaping @Sendable (String, TimeInterval) async -> HeadGestureResponse = {
            _,
            _ in .unavailable(reason: "未接続")
        },
        sleep: @escaping DetectionEngine.Sleeping = { try? await Task.sleep(for: $0) }
    ) -> DetectionEngine {
        let engine = DetectionEngine(
            idleMonitor: MacIdleMonitor(probe: { idle.read() }),
            frontmostMonitor: FrontmostAppMonitor(probe: { "Xcode" }),
            musicController: SilentMusic(),
            sleep: sleep
        )
        var actions = spy.makeActions()
        actions.askHeadGesture = headGesture
        engine.actions = actions
        engine.thresholds = thresholds
        engine.iphoneState = .unreachable
        engine.onEvent = { pet.record($0) }
        engine.onPromptDismissed = { pet.recordDismissal() }
        return engine
    }

    /// 別タスクの決着を待つ。実時間で決め打ちすると、並列実行時の混雑で簡単にフラフラになる。
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: - 休憩

    @Test("休憩中は材料すら集めず、撮らないし喋らない")
    func breakSkipsEverything() async {
        let spy = ActionSpy()
        let pet = PetSpy()
        let engine = engine(idle: IdleClock(5), spy: spy, pet: pet, thresholds: thresholds())
        let base = Date()

        engine.startBreak(now: base)
        let decision = await engine.evaluate(now: base.addingTimeInterval(1))

        #expect(decision.state == .normal)
        #expect(decision.reason.contains("休憩中"))
        #expect(engine.state == .normal)
        // 材料を集める前に返しているので、カメラを開く余地もない。
        #expect(engine.lastSignals == nil)
        #expect(spy.macPhotos == 0)
        #expect(spy.iphoneShots == 0)
        #expect(spy.spoken.isEmpty)
        #expect(spy.interrupted.isEmpty)
        #expect(spy.posts.isEmpty)
    }

    @Test("休憩の始まりはペットに伝わる")
    func breakAnnouncesItself() async {
        let pet = PetSpy()
        let engine = engine(
            idle: IdleClock(5),
            spy: ActionSpy(),
            pet: pet,
            thresholds: thresholds(breakDurationSeconds: 900)
        )

        engine.startBreak()

        #expect(pet.events.count == 1)
        #expect(pet.events.first?.state == .normal)
        #expect(pet.events.first?.line == "15 分だけ、待ってる。")
    }

    @Test("休憩が明けたら、次の tick で勝手に見張りへ戻る")
    func breakEndsOnItsOwn() async {
        let spy = ActionSpy()
        let engine = engine(
            idle: IdleClock(5),
            spy: spy,
            pet: PetSpy(),
            thresholds: thresholds(breakDurationSeconds: 10)
        )
        let base = Date()

        engine.startBreak(now: base)
        let decision = await engine.evaluate(now: base.addingTimeInterval(20))

        #expect(engine.breakUntil == nil)
        #expect(decision.state == .confirmed)
        #expect(spy.macPhotos == 1)
        #expect(engine.log.contains { $0.reason.contains("休憩が明けた") })
    }

    @Test("監視を止めても休憩は残り、endBreak で消える")
    func stopKeepsTheBreak() async {
        let engine = engine(idle: IdleClock(5), spy: ActionSpy(), pet: PetSpy(), thresholds: thresholds())

        engine.startBreak()
        #expect(engine.breakUntil != nil)

        // 休憩と監視の開始 / 停止は別の話。止めたからといって休憩を取り消さない。
        engine.stop()
        #expect(engine.breakUntil != nil)

        engine.endBreak()
        #expect(engine.breakUntil == nil)
    }

    // MARK: - 問いかけの回数

    @Test("同じエピソードでは問いかけは 1 回だけ")
    func promptOncePerEpisode() async {
        let idle = IdleClock()
        let pet = PetSpy()
        let engine = engine(idle: idle, spy: ActionSpy(), pet: pet, thresholds: thresholds())

        idle.set(0)
        await engine.evaluate()
        idle.set(1)
        await engine.evaluate()
        idle.set(2)
        await engine.evaluate()
        // 確定まで上がって疑いに戻っても、同じエピソードなので出し直さない。
        idle.set(5)
        await engine.evaluate()
        idle.set(2)
        await engine.evaluate()

        #expect(pet.prompts.count == 1)
        #expect(pet.prompts.first?.question == DetectionEngine.breakQuestion)
    }

    @Test("正常に戻ってから疑いになれば、もう一度だけ問いかける")
    func promptAgainAfterANewEpisode() async {
        let idle = IdleClock()
        let pet = PetSpy()
        let engine = engine(idle: idle, spy: ActionSpy(), pet: pet, thresholds: thresholds())

        idle.set(1)
        await engine.evaluate()
        idle.set(0)
        await engine.evaluate()
        idle.set(1)
        await engine.evaluate()

        #expect(pet.prompts.count == 2)
    }

    @Test("疑いを飛ばして確定した回には問いかけない")
    func straightToConfirmedDoesNotPrompt() async {
        let idle = IdleClock()
        let pet = PetSpy()
        let engine = engine(idle: idle, spy: ActionSpy(), pet: pet, thresholds: thresholds())

        idle.set(0)
        await engine.evaluate()
        idle.set(5)
        await engine.evaluate()

        #expect(engine.state == .confirmed)
        #expect(pet.prompts.isEmpty)
    }

    @Test("正常に戻ると、セリフの無い正常イベントが 1 回流れる")
    func returningToNormalSignalsThePet() async {
        let idle = IdleClock()
        let pet = PetSpy()
        let engine = engine(idle: idle, spy: ActionSpy(), pet: pet, thresholds: thresholds())

        idle.set(1)
        await engine.evaluate()
        #expect(pet.returnSignals == 0)

        idle.set(0)
        await engine.evaluate()
        #expect(pet.returnSignals == 1)

        // 正常が続く間は流し続けない。
        await engine.evaluate()
        #expect(pet.returnSignals == 1)
    }

    // MARK: - 問いかけへの答え

    @Test("はい と答えると休憩に入り、問いかけは引っ込む")
    func yesStartsTheBreak() async throws {
        let idle = IdleClock(1)
        let pet = PetSpy()
        let engine = engine(idle: idle, spy: ActionSpy(), pet: pet, thresholds: thresholds())

        await engine.evaluate()
        let prompt = try #require(pet.prompts.first)

        let before = Date()
        prompt.onAnswer(true)
        await settle(until: { engine.breakUntil != nil })

        let until = try #require(engine.breakUntil)
        #expect(until.timeIntervalSince(before) >= 900)
        #expect(until.timeIntervalSince(before) < 902)
        #expect(pet.dismissals == 1)
    }

    @Test("いいえ と答えると問いかけだけ引っ込み、見張りは続く")
    func noKeepsWatching() async throws {
        let idle = IdleClock(1)
        let pet = PetSpy()
        let engine = engine(idle: idle, spy: ActionSpy(), pet: pet, thresholds: thresholds())

        await engine.evaluate()
        let prompt = try #require(pet.prompts.first)

        prompt.onAnswer(false)
        await settle(until: { pet.dismissals == 1 })

        #expect(engine.breakUntil == nil)
        #expect(pet.dismissals == 1)
    }

    @Test("答えを採るのは先に来た 1 つだけ")
    func onlyTheFirstAnswerCounts() async throws {
        let idle = IdleClock(1)
        let pet = PetSpy()
        let engine = engine(idle: idle, spy: ActionSpy(), pet: pet, thresholds: thresholds())

        await engine.evaluate()
        let prompt = try #require(pet.prompts.first)

        prompt.onAnswer(false)
        await settle(until: { pet.dismissals == 1 })
        prompt.onAnswer(true)
        await settle(until: { engine.breakUntil != nil })

        #expect(engine.breakUntil == nil)
        #expect(pet.dismissals == 1)
    }

    @Test("返事が無ければ引っ込めるだけ。休憩には入らない")
    func silenceJustDismisses() async {
        let idle = IdleClock(1)
        let pet = PetSpy()
        let engine = engine(
            idle: idle,
            spy: ActionSpy(),
            pet: pet,
            thresholds: thresholds(promptTimeoutSeconds: 100),
            // 実時間を待たずに時間切れへ倒す。
            sleep: { _ in }
        )

        await engine.evaluate()
        await settle(until: { pet.dismissals == 1 })

        #expect(pet.dismissals == 1)
        #expect(engine.breakUntil == nil)
        #expect(engine.state == .suspected)
    }

    @Test("エピソードが終わると、答えの出ていない問いかけも閉じる")
    func returningToNormalClosesThePrompt() async {
        let idle = IdleClock()
        let pet = PetSpy()
        let engine = engine(idle: idle, spy: ActionSpy(), pet: pet, thresholds: thresholds())

        idle.set(1)
        await engine.evaluate()
        #expect(pet.dismissals == 0)

        idle.set(0)
        await engine.evaluate()

        #expect(pet.dismissals == 1)
        #expect(engine.breakUntil == nil)
    }

    @Test("監視を止めると、出したままの問いかけを閉じる")
    func stopClosesThePrompt() async {
        let pet = PetSpy()
        let engine = engine(idle: IdleClock(1), spy: ActionSpy(), pet: pet, thresholds: thresholds())

        await engine.evaluate()
        engine.stop()

        #expect(pet.dismissals == 1)
    }

    @Test("疑いの途中で監視を止めると、エピソードもそこで終わる")
    func stopFinishesTheEpisode() async {
        let pet = PetSpy()
        let engine = engine(idle: IdleClock(1), spy: ActionSpy(), pet: pet, thresholds: thresholds())

        await engine.evaluate()
        #expect(engine.state == .suspected)
        #expect(pet.returnSignals == 0)

        engine.stop()

        // 固定アニメを解く合図。問いかけを閉じるのは 1 回だけ。
        #expect(pet.returnSignals == 1)
        #expect(pet.dismissals == 1)
    }

    @Test("正常のまま監視を止めても、ペットには何も流れない")
    func stopWhileNormalSaysNothing() async {
        let pet = PetSpy()
        let engine = engine(idle: IdleClock(0), spy: ActionSpy(), pet: pet, thresholds: thresholds())

        await engine.evaluate()
        #expect(engine.state == .normal)

        engine.stop()

        #expect(pet.events.isEmpty)
        #expect(pet.dismissals == 0)
    }

    // MARK: - 首振り

    @Test("うなずきでも休憩に入る")
    func nodStartsTheBreak() async {
        let pet = PetSpy()
        let engine = engine(
            idle: IdleClock(1),
            spy: ActionSpy(),
            pet: pet,
            thresholds: thresholds(),
            headGesture: { _, _ in .yes }
        )

        await engine.evaluate()
        await settle(until: { engine.breakUntil != nil })

        #expect(engine.breakUntil != nil)
        #expect(pet.dismissals == 1)
    }

    @Test("首を振ったら休憩には入らず、問いかけだけ引っ込む")
    func shakeKeepsWatching() async {
        let pet = PetSpy()
        let engine = engine(
            idle: IdleClock(1),
            spy: ActionSpy(),
            pet: pet,
            thresholds: thresholds(),
            headGesture: { _, _ in .no }
        )

        await engine.evaluate()
        await settle(until: { pet.dismissals == 1 })

        #expect(engine.breakUntil == nil)
        #expect(pet.dismissals == 1)
    }

    @Test("AirPods が無いときは首振りの結果で何も起きない")
    func unavailableHeadGestureChangesNothing() async {
        let pet = PetSpy()
        let engine = engine(
            idle: IdleClock(1),
            spy: ActionSpy(),
            pet: pet,
            thresholds: thresholds(),
            headGesture: { _, _ in .unavailable(reason: "未接続") }
        )

        await engine.evaluate()
        // 決着しないことの確認なので、少しだけ回してから見る。
        await settle(until: { pet.dismissals > 0 })

        #expect(engine.breakUntil == nil)
        #expect(pet.dismissals == 0)
        #expect(pet.prompts.count == 1)
    }
}

@Suite("問いかけ 1 回分の状態")
@MainActor
struct BreakPromptSessionTests {

    @Test("採用するのは最初の 1 回だけ")
    func claimOnce() {
        let session = BreakPromptSession()

        #expect(session.isAwaitingAnswer)
        #expect(session.claim(sessionID: session.id))
        #expect(session.claim(sessionID: session.id) == false)
        #expect(session.isAwaitingAnswer == false)
    }

    @Test("別の問いかけ宛ての答えは通さない")
    func rejectsOtherSessions() {
        let session = BreakPromptSession()
        let other = BreakPromptSession()

        #expect(session.claim(sessionID: other.id) == false)
        // 弾いただけなので、本来の答えはまだ受け付けられる。
        #expect(session.claim(sessionID: session.id))
    }

    @Test("閉じたあとの答えは通さない")
    func settledSessionRejectsAnswers() {
        let session = BreakPromptSession()

        session.settle()

        #expect(session.isAwaitingAnswer == false)
        #expect(session.claim(sessionID: session.id) == false)
    }
}
