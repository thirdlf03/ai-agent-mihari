import Foundation
import Testing

@testable import MihariCore

/// メンヘラモード。間隔ごとの投稿、証拠の撮り直し、戻ってきたときの締め方を見る。
@Suite("メンヘラモード")
@MainActor
struct DetectionClingyTests {

    /// メンヘラモードに入った状態のエンジンを作る。
    private func clingyEngine(
        idle: IdleClock,
        spy: ActionSpy,
        pet: PetSpy? = nil,
        thresholds: DetectionThresholds,
        iphone: SpeechRequest.IPhoneState = .unreachable
    ) async -> DetectionEngine {
        let engine = makeDetectionEngine(
            idle: idle,
            spy: spy,
            pet: pet,
            thresholds: thresholds,
            iphone: iphone
        )
        engine.runDebugStep(.startClingy)
        await settle(until: {
            if case .clingy = engine.state { return true }
            return false
        })
        return engine
    }

    /// 投稿の 1 行目。
    private func headline(_ post: ActionSpy.Post) -> String {
        post.text.components(separatedBy: "\n").first ?? ""
    }

    @Test("間隔ごとにテキストだけを投げ、回数でセリフの区分が変わる")
    func postsTextOnEveryInterval() async {
        let spy = ActionSpy()
        let pet = PetSpy()
        let base = Date()
        let engine = await clingyEngine(
            idle: IdleClock(600),
            spy: spy,
            pet: pet,
            // 撮り直しは来ないところまで遠ざけて、テキストだけの投稿を見る。
            thresholds: .quick(clingyIntervalSeconds: 20, clingyEvidenceIntervalSeconds: 100_000)
        )

        // 入った直後は投げない。間隔ぶん待ってから 1 通目。
        await engine.evaluate(now: base.addingTimeInterval(5))
        #expect(spy.posts.isEmpty)

        for round in 1...6 {
            await engine.evaluate(now: base.addingTimeInterval(Double(round) * 20 + 1))
        }

        #expect(spy.posts.count == 6)
        #expect(spy.posts.allSatisfy { $0.image == nil })
        #expect(spy.posts.allSatisfy { $0.mention })
        #expect(spy.posts.allSatisfy { $0.text.contains("戻ってこないまま") })

        let clingy1 = BundledVoiceLines.shared.lines(for: .clingy1)
        let clingy2 = BundledVoiceLines.shared.lines(for: .clingy2)
        let clingy3 = BundledVoiceLines.shared.lines(for: .clingy3)
        #expect(clingy1.contains(headline(spy.posts[0])))
        #expect(clingy1.contains(headline(spy.posts[1])))
        #expect(clingy2.contains(headline(spy.posts[2])))
        #expect(clingy2.contains(headline(spy.posts[4])))
        #expect(clingy3.contains(headline(spy.posts[5])))

        // 同じセリフをペットも喋る。
        #expect(pet.lines.contains(headline(spy.posts[0])))
        #expect(engine.escalationStage == PetEvent.clingyStage)
    }

    @Test("撮り直しの回は、テキストと重ねずに証拠つき 1 件にまとめる")
    func evidenceRoundIsASinglePost() async {
        let spy = ActionSpy()
        let base = Date()
        let engine = await clingyEngine(
            idle: IdleClock(600),
            spy: spy,
            thresholds: .quick(clingyIntervalSeconds: 20, clingyEvidenceIntervalSeconds: 60)
        )

        await engine.evaluate(now: base.addingTimeInterval(21))
        await engine.evaluate(now: base.addingTimeInterval(42))
        await engine.evaluate(now: base.addingTimeInterval(63))

        #expect(spy.posts.count == 3)
        #expect(spy.posts[0].image == nil)
        #expect(spy.posts[1].image == nil)
        let evidence = spy.posts[2]
        #expect(evidence.image != nil)
        #expect(evidence.filename == "camera.png")
        #expect(BundledVoiceLines.shared.lines(for: .clingyEvidence).contains(headline(evidence)))
        #expect(spy.macPhotos == 1)
        #expect(engine.lastEvidenceAt != nil)
    }

    @Test("撮り直しの取り先は晒しと同じで、iPhone を触っていれば画面を撮る")
    func evidenceFollowsThePhone() async {
        let spy = ActionSpy()
        let base = Date()
        let engine = await clingyEngine(
            idle: IdleClock(600),
            spy: spy,
            thresholds: .quick(clingyIntervalSeconds: 10, clingyEvidenceIntervalSeconds: 10),
            iphone: .active
        )

        await engine.evaluate(now: base.addingTimeInterval(11))

        #expect(spy.iphoneShots == 1)
        #expect(spy.posts.first?.filename == "iphone.png")
    }

    @Test("戻ってきたら returned をメンションなしで 1 件だけ送り、正常に戻る")
    func returningPostsOnceWithoutMention() async {
        let spy = ActionSpy()
        let pet = PetSpy()
        let idle = IdleClock(600)
        let base = Date()
        let engine = await clingyEngine(
            idle: idle,
            spy: spy,
            pet: pet,
            thresholds: .quick(clingyIntervalSeconds: 20)
        )

        idle.set(0)
        let decision = await engine.evaluate(now: base.addingTimeInterval(30))

        #expect(decision.state == .normal)
        #expect(engine.state == .normal)
        #expect(engine.escalationStage == 0)
        #expect(spy.posts.count == 1)
        #expect(spy.posts.first?.mention == false)
        #expect(spy.posts.first?.image == nil)
        let returned = BundledVoiceLines.shared.lines(for: .returned)
        #expect(returned.contains(spy.posts.first?.text ?? ""))
        #expect(returned.contains(pet.lines.last ?? ""))

        // 二度は送らない。疑いの数え直しも済んでいる。
        await engine.evaluate(now: base.addingTimeInterval(60))
        #expect(spy.posts.count == 1)
        #expect(engine.state == .normal)
    }
}

/// 新フローで使うセリフの区分が、同封セリフに揃っているかを見る。
@Suite("監視ループ v2 のセリフ区分")
struct DetectionVoiceKindTests {

    @Test("疑い〜メンヘラの 17 区分はすべて同封セリフから引ける")
    func everyKindHasBundledLines() {
        let kinds: [BundledVoiceKind] = [
            .suspectReach, .suspectReachPhone, .suspectTouched, .suspectMissed, .suspectTimeout,
            .askQuestion, .askQuestionPhone, .gestureYes, .gestureNo, .askTimeout,
            .finalWarn, .finalWarnPhone,
            .clingy1, .clingy2, .clingy3, .clingyEvidence, .returned,
        ]
        for kind in kinds {
            #expect(!BundledVoiceLines.shared.lines(for: kind).isEmpty, "\(kind.rawValue) のセリフが無い")
        }
    }
}

@Suite("集中継続")
@MainActor
struct DetectionFocusStreakTests {

    /// 褒められた回数を数える箱。
    private final class PraiseCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func record() { lock.withLock { _count += 1 } }
    }

    private func engine(idle: IdleClock, praise: PraiseCounter) -> DetectionEngine {
        let engine = makeDetectionEngine(
            idle: idle,
            spy: ActionSpy(),
            thresholds: DetectionThresholds.production.withFocusStreakInterval(60)
        )
        engine.onFocusStreak = { praise.record() }
        return engine
    }

    @Test("既定の間隔は 15 分")
    func defaultIntervalIsFifteenMinutes() {
        #expect(DetectionThresholds().focusStreakIntervalSeconds == 900)
    }

    @Test("正常が続くと間隔ごとに褒める")
    func praisesOnEveryInterval() async {
        let idle = IdleClock(10)
        let praise = PraiseCounter()
        let engine = engine(idle: idle, praise: praise)
        let start = Date()

        await engine.evaluate(now: start)
        #expect(praise.count == 0)

        await engine.evaluate(now: start.addingTimeInterval(59))
        #expect(praise.count == 0)

        await engine.evaluate(now: start.addingTimeInterval(60))
        #expect(praise.count == 1)

        await engine.evaluate(now: start.addingTimeInterval(121))
        #expect(praise.count == 2)
    }

    @Test("疑いに入ったら数え直す")
    func suspicionResetsTheStreak() async {
        let idle = IdleClock(10)
        let praise = PraiseCounter()
        let engine = engine(idle: idle, praise: praise)
        let start = Date()

        await engine.evaluate(now: start)
        // 疑いに入る(= 集中が途切れた)。
        idle.set(150)
        await engine.evaluate(now: start.addingTimeInterval(30))
        await settle(until: { !engine.isCheckRunning })
        idle.set(10)

        // 途切れる前から数えていれば、ここで 1 回目が出てしまう。
        await engine.evaluate(now: start.addingTimeInterval(61))
        #expect(praise.count == 0)

        await engine.evaluate(now: start.addingTimeInterval(122))
        #expect(praise.count == 1)
    }

    @Test("休憩に入ったら数え直す")
    func breakResetsTheStreak() async {
        let idle = IdleClock(10)
        let praise = PraiseCounter()
        let engine = engine(idle: idle, praise: praise)
        let start = Date()

        await engine.evaluate(now: start)
        engine.startBreak(now: start.addingTimeInterval(10))

        // 休憩中は評価そのものを飛ばすので、褒めることもない。
        await engine.evaluate(now: start.addingTimeInterval(61))
        #expect(praise.count == 0)

        engine.endBreak()
        await engine.evaluate(now: start.addingTimeInterval(70))
        #expect(praise.count == 0)

        await engine.evaluate(now: start.addingTimeInterval(131))
        #expect(praise.count == 1)
    }

    @Test("監視を止めたら数え直す")
    func stoppingResetsTheStreak() async {
        let idle = IdleClock(10)
        let praise = PraiseCounter()
        let engine = engine(idle: idle, praise: praise)
        let start = Date()

        await engine.evaluate(now: start)
        engine.stop()

        await engine.evaluate(now: start.addingTimeInterval(61))
        #expect(praise.count == 0)

        await engine.evaluate(now: start.addingTimeInterval(122))
        #expect(praise.count == 1)
    }
}
