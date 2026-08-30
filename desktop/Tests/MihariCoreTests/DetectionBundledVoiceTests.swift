import Foundation
import Testing

@testable import MihariCore

/// 同封音声のモード(既定)での検知のふるまい。
/// bridge にセリフを作らせず、`lines.json` の区分から選んで喋る。
@Suite("同封音声での検知")
@MainActor
struct DetectionBundledVoiceTests {

    /// 音楽の有無を固定するためのスタブ。
    private struct StubMusic: MusicControlling {
        let playing: NowPlaying
        func nowPlaying() async -> NowPlaying { playing }
        func stopPlaying() async -> MusicStopOutcome { .nothingWasPlaying }
        func resumePlaying(_ outcome: MusicStopOutcome) async {}
    }

    /// ペットに届いたイベントを覚えておく箱。
    private final class PetSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [PetEvent] = []
        var events: [PetEvent] { lock.withLock { _events } }
        func record(_ event: PetEvent) { lock.withLock { _events.append(event) } }
    }

    private func engine(
        idle: TimeInterval,
        spy: ActionSpy,
        pet: PetSpy,
        music: NowPlaying = .silent
    ) -> DetectionEngine {
        let engine = DetectionEngine(
            idleMonitor: MacIdleMonitor(probe: { idle }),
            frontmostMonitor: FrontmostAppMonitor(probe: { "Safari" }),
            musicController: StubMusic(playing: music)
        )
        engine.thresholds = .production
        engine.actions = spy.makeActions()
        engine.onEvent = { pet.record($0) }
        return engine
    }

    @Test("既定は同封音声")
    func bundledIsTheDefault() {
        let engine = DetectionEngine(idleMonitor: MacIdleMonitor(probe: { 0 }))
        #expect(engine.voiceMode == .bundled)
    }

    @Test("bridge にセリフを作らせず、iPhone 操作中の区分から喋る")
    func speaksBundledIPhoneLine() async {
        let spy = ActionSpy()
        let pet = PetSpy()
        let engine = engine(idle: 600, spy: spy, pet: pet)
        engine.iphoneState = .active

        await engine.evaluate()

        #expect(spy.spoken.isEmpty)
        let line = pet.events.first?.line ?? ""
        #expect(BundledVoiceLines.shared.lines(for: .iphoneActive).contains(line))
        #expect(pet.events.first?.audio != nil)
    }

    @Test("寝ていると見立てたら、寝ている区分から喋る")
    func speaksBundledSleepingLine() async {
        // `ActionSpy.classify` は常に .sleeping を返す。
        let spy = ActionSpy()
        let pet = PetSpy()
        let engine = engine(idle: 600, spy: spy, pet: pet)
        engine.iphoneState = .unreachable

        await engine.evaluate()

        let line = pet.events.first?.line ?? ""
        #expect(BundledVoiceLines.shared.lines(for: .sleeping).contains(line))
    }

    @Test("疑いの段階は nudge の区分から喋る")
    func speaksBundledNudgeLine() async {
        let spy = ActionSpy()
        let pet = PetSpy()
        let engine = engine(idle: 150, spy: spy, pet: pet)
        engine.iphoneState = .idle

        await engine.evaluate()

        let line = pet.events.first?.line ?? ""
        #expect(BundledVoiceLines.shared.lines(for: .nudge).contains(line))
    }

    @Test("音楽を止めて聞かせるときは、吹き出しに warn の区分を出す")
    func interruptShowsBundledWarnLine() async {
        let spy = ActionSpy()
        let pet = PetSpy()
        let engine = engine(idle: 600, spy: spy, pet: pet, music: .playing(.spotify))
        engine.iphoneState = .unreachable

        let decision = await engine.evaluate()

        #expect(spy.interrupted.count == 1)
        let line = pet.events.first?.line ?? ""
        #expect(BundledVoiceLines.shared.lines(for: .warn).contains(line))
        #expect(line != decision.reason)
    }

    @Test("iPhone のスクショは Discord の文面のために読ませる")
    func readsTheScreenForDiscord() async {
        let spy = ActionSpy()
        let pet = PetSpy()
        let engine = engine(idle: 600, spy: spy, pet: pet)
        engine.iphoneState = .active

        await engine.evaluate()

        #expect(spy.screenReads.count == 1)
        #expect(spy.screenReads.first?.screenshotPNG == Data("iphone".utf8))
        // 読み取れた内容が投稿の 1 行目に出る。
        #expect(spy.posts.first?.0.contains("YouTube") == true)
    }

    @Test("カメラで撮ったときは画面を読ませない")
    func doesNotReadTheScreenForCameraPhotos() async {
        let spy = ActionSpy()
        let pet = PetSpy()
        let engine = engine(idle: 600, spy: spy, pet: pet)
        engine.iphoneState = .unreachable

        await engine.evaluate()

        #expect(spy.screenReads.isEmpty)
    }

    @Test("画面を読めなくても、喋ることも送ることも止めない")
    func keepsGoingWhenTheScreenCannotBeRead() async {
        let spy = ActionSpy()
        spy.screenReading = nil
        let pet = PetSpy()
        let engine = engine(idle: 600, spy: spy, pet: pet)
        engine.iphoneState = .active

        await engine.evaluate()

        #expect(pet.events.first?.line.isEmpty == false)
        #expect(spy.posts.count == 1)
    }
}

@Suite("集中継続")
@MainActor
struct DetectionFocusStreakTests {

    /// 無操作秒数をテストの途中で変えるための箱。
    private final class IdleBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _seconds: TimeInterval
        init(_ seconds: TimeInterval) { _seconds = seconds }
        var seconds: TimeInterval {
            get { lock.withLock { _seconds } }
            set { lock.withLock { _seconds = newValue } }
        }
    }

    /// 褒められた回数を数える箱。
    private final class PraiseCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func record() { lock.withLock { _count += 1 } }
    }

    private struct SilentMusic: MusicControlling {
        func nowPlaying() async -> NowPlaying { .silent }
        func stopPlaying() async -> MusicStopOutcome { .nothingWasPlaying }
        func resumePlaying(_ outcome: MusicStopOutcome) async {}
    }

    private func engine(idle: IdleBox, praise: PraiseCounter) -> DetectionEngine {
        let engine = DetectionEngine(
            idleMonitor: MacIdleMonitor(probe: { idle.seconds }),
            musicController: SilentMusic()
        )
        engine.thresholds = DetectionThresholds.production.withFocusStreakInterval(60)
        engine.actions = ActionSpy().makeActions()
        engine.onFocusStreak = { praise.record() }
        return engine
    }

    @Test("既定の間隔は 15 分")
    func defaultIntervalIsFifteenMinutes() {
        #expect(DetectionThresholds().focusStreakIntervalSeconds == 900)
    }

    @Test("正常が続くと間隔ごとに褒める")
    func praisesOnEveryInterval() async {
        let idle = IdleBox(10)
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
        let idle = IdleBox(10)
        let praise = PraiseCounter()
        let engine = engine(idle: idle, praise: praise)
        let start = Date()

        await engine.evaluate(now: start)
        // 疑いに入る(= 集中が途切れた)。
        idle.seconds = 150
        await engine.evaluate(now: start.addingTimeInterval(30))
        idle.seconds = 10

        // 途切れる前から数えていれば、ここで 1 回目が出てしまう。
        await engine.evaluate(now: start.addingTimeInterval(61))
        #expect(praise.count == 0)

        await engine.evaluate(now: start.addingTimeInterval(122))
        #expect(praise.count == 1)
    }

    @Test("休憩に入ったら数え直す")
    func breakResetsTheStreak() async {
        let idle = IdleBox(10)
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
        let idle = IdleBox(10)
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
