import Foundation
import LocalAuthentication
import Testing

@testable import MihariCore

/// 遷移表(正常 → 疑い 1 → 疑い 2 → 疑い 3 → 晒し → メンヘラ)の 1 行ずつを確かめる。
@Suite("検知の状態遷移")
@MainActor
struct DetectionStateMachineTests {

    /// 疑い 1 の Touch ID チェックが決着するまで待つ。
    private func settleCheck(_ engine: DetectionEngine) async {
        await settle(until: { !engine.isCheckRunning })
    }

    @Test("触っている間は何も呼ばれない")
    func normalDoesNothing() async {
        let spy = ActionSpy()
        let pet = PetSpy()
        let engine = makeDetectionEngine(idle: IdleClock(1), spy: spy, pet: pet)

        let decision = await engine.evaluate()

        #expect(decision.state == .normal)
        #expect(spy.presenceChecks.isEmpty)
        #expect(spy.macPhotos == 0)
        #expect(spy.posts.isEmpty)
        #expect(pet.events.isEmpty)
        #expect(engine.log.isEmpty)
    }

    @Test("無操作が閾値を超えると疑い 1 に入り、すぐ Touch ID を確かめる")
    func idleEntersFirstSuspect() async {
        let spy = ActionSpy()
        let pet = PetSpy()
        let engine = makeDetectionEngine(idle: IdleClock(10), spy: spy, pet: pet)

        let decision = await engine.evaluate()

        #expect(decision.state == .suspect(stage: 1))
        #expect(engine.isCheckRunning)
        await settleCheck(engine)
        #expect(spy.presenceChecks == [false])
        // ペットは待つ姿に固定される。セリフとカットインは演出側が出す。
        #expect(pet.events.first?.state == .suspected)
        #expect(pet.events.first?.escalationStage == 1)
    }

    @Test("iPhone を触っていると、疑い 1 の演出にもそれを伝える")
    func firstSuspectKnowsAboutThePhone() async {
        let spy = ActionSpy()
        let engine = makeDetectionEngine(idle: IdleClock(10), spy: spy, iphone: .active)

        await engine.evaluate()
        await settleCheck(engine)

        #expect(spy.presenceChecks == [true])
    }

    @Test("Touch ID に成功したら正常に戻る。猶予は付けない")
    func touchIDSuccessReturnsToNormal() async {
        let spy = ActionSpy()
        spy.presenceOutcome = .stamped
        let pet = PetSpy()
        let engine = makeDetectionEngine(idle: IdleClock(10), spy: spy, pet: pet)

        await engine.evaluate()
        await settle(until: { engine.state == .normal })

        #expect(engine.state == .normal)
        #expect(engine.escalationStage == 0)
        #expect(pet.returnSignals == 1)
        // 猶予が付いていたら、次の評価で疑い直さないはず。付けていないので疑い直す。
        await engine.evaluate()
        #expect(engine.state == .suspect(stage: 1))
    }

    @Test("Touch ID が空振りしたら待ちに入り、段の間隔ぶんで疑い 2 へ上がる")
    func touchIDMissMovesToSecondSuspect() async throws {
        let spy = ActionSpy()
        spy.presenceOutcome = .failed
        let pet = PetSpy()
        let engine = makeDetectionEngine(idle: IdleClock(10), spy: spy, pet: pet)
        let base = Date()

        await engine.evaluate(now: base)
        await settleCheck(engine)
        #expect(engine.state == .suspect(stage: 1))

        // 待ちが明けるまでは上がらない。
        await engine.evaluate(now: base.addingTimeInterval(1))
        #expect(engine.state == .suspect(stage: 1))

        await engine.evaluate(now: base.addingTimeInterval(6))
        #expect(engine.state == .suspect(stage: 2))
        // 疑い 2 は同封の質問を、はい / いいえの問いかけとして出す。
        let prompt = try #require(pet.prompts.first)
        #expect(BundledVoiceLines.shared.lines(for: .askQuestion).contains(prompt.question))
    }

    @Test("疑い 2 でうなずいたら、縦に振ったと言って正常に戻る")
    func nodReturnsToNormal() async {
        let spy = ActionSpy()
        spy.presenceOutcome = .failed
        let pet = PetSpy()
        let engine = makeDetectionEngine(
            idle: IdleClock(10),
            spy: spy,
            pet: pet,
            headGesture: { _, _ in .yes }
        )
        let base = Date()

        await engine.evaluate(now: base)
        await settleCheck(engine)
        await engine.evaluate(now: base.addingTimeInterval(6))
        await settle(until: { engine.state == .normal })

        #expect(engine.state == .normal)
        #expect(pet.dismissals == 1)
        #expect(pet.lines.contains { BundledVoiceLines.shared.lines(for: .gestureYes).contains($0) })
    }

    @Test("疑い 2 で首を横に振ったら、横に振ったと言って待ちに入る")
    func shakeKeepsSuspecting() async {
        let spy = ActionSpy()
        spy.presenceOutcome = .failed
        let pet = PetSpy()
        let engine = makeDetectionEngine(
            idle: IdleClock(10),
            spy: spy,
            pet: pet,
            headGesture: { _, _ in .no }
        )
        let base = Date()

        await engine.evaluate(now: base)
        await settleCheck(engine)
        await engine.evaluate(now: base.addingTimeInterval(6))
        await settle(until: { !engine.isCheckRunning })

        #expect(engine.state == .suspect(stage: 2))
        #expect(pet.lines.contains { BundledVoiceLines.shared.lines(for: .gestureNo).contains($0) })
    }

    @Test("疑い 2 に反応が無ければ、無反応のセリフを言って待ちに入る")
    func silenceKeepsSuspecting() async {
        let spy = ActionSpy()
        spy.presenceOutcome = .failed
        let pet = PetSpy()
        let engine = makeDetectionEngine(
            idle: IdleClock(10),
            spy: spy,
            pet: pet,
            // 実時間を待たずに時間切れへ倒す。
            sleep: { _ in }
        )
        let base = Date()

        await engine.evaluate(now: base)
        await settleCheck(engine)
        await engine.evaluate(now: base.addingTimeInterval(6))
        await settle(until: { !engine.isCheckRunning })

        #expect(engine.state == .suspect(stage: 2))
        #expect(pet.dismissals == 1)
        #expect(pet.lines.contains { BundledVoiceLines.shared.lines(for: .askTimeout).contains($0) })
    }

    @Test("疑い 3 は最終警告を言うだけで、確かめない")
    func thirdSuspectOnlyWarns() async {
        let spy = ActionSpy()
        spy.presenceOutcome = .failed
        let pet = PetSpy()
        let engine = makeDetectionEngine(idle: IdleClock(10), spy: spy, pet: pet, sleep: { _ in })
        let base = Date()

        await engine.evaluate(now: base)
        await settleCheck(engine)
        await engine.evaluate(now: base.addingTimeInterval(6))
        await settle(until: { !engine.isCheckRunning })
        await engine.evaluate(now: base.addingTimeInterval(12))

        #expect(engine.state == .suspect(stage: 3))
        #expect(engine.isCheckRunning == false)
        #expect(spy.presenceChecks.count == 1)
        #expect(pet.lines.contains { BundledVoiceLines.shared.lines(for: .finalWarn).contains($0) })
        #expect(spy.posts.isEmpty)
    }

    @Test("疑い 3 のあとも動かなければ晒し、そのままメンヘラモードに入る")
    func exposureLeadsToClingy() async {
        let spy = ActionSpy()
        spy.presenceOutcome = .failed
        let pet = PetSpy()
        let engine = makeDetectionEngine(idle: IdleClock(10), spy: spy, pet: pet, sleep: { _ in })
        let base = Date()

        await engine.evaluate(now: base)
        await settleCheck(engine)
        await engine.evaluate(now: base.addingTimeInterval(6))
        await settle(until: { !engine.isCheckRunning })
        await engine.evaluate(now: base.addingTimeInterval(12))
        let decision = await engine.evaluate(now: base.addingTimeInterval(18))

        #expect(decision.state == .exposing)
        #expect(decision.evidence == .macCamera)
        #expect(spy.macPhotos == 1)
        #expect(spy.posts.count == 1)
        #expect(spy.posts.first?.mention == true)
        #expect(engine.state == .clingy(since: base.addingTimeInterval(18), count: 0))
        #expect(engine.escalationStage == PetEvent.clingyStage)
    }

    @Test("疑いの途中で入力があれば、黙って正常に戻る")
    func inputDuringSuspicionReturnsSilently() async {
        let spy = ActionSpy()
        spy.presenceOutcome = .failed
        let idle = IdleClock(10)
        let pet = PetSpy()
        let engine = makeDetectionEngine(idle: idle, spy: spy, pet: pet)

        await engine.evaluate()
        await settleCheck(engine)
        idle.set(0)
        let decision = await engine.evaluate()

        #expect(decision.state == .normal)
        #expect(engine.state == .normal)
        // 責める理由がないのでセリフは出さない。
        #expect(pet.lines.isEmpty)
        #expect(pet.returnSignals == 1)
        #expect(spy.posts.isEmpty)
    }

    @Test("チェックの最中に入力があれば、結果を待たずに正常へ戻す")
    func inputDuringCheckDropsTheResult() async {
        let spy = ActionSpy()
        spy.presenceOutcome = .stamped
        let idle = IdleClock(10)
        let pet = PetSpy()
        let engine = makeDetectionEngine(idle: idle, spy: spy, pet: pet)

        await engine.evaluate()
        #expect(engine.isCheckRunning)
        idle.set(0)
        await engine.evaluate()

        #expect(engine.state == .normal)
        // ダイアログとカットインを閉じてもらう。
        await settle(until: { spy.presenceCancels == 1 })
        #expect(spy.presenceCancels == 1)

        // 遅れて届いた「成功」で段が動かないことを見る。
        await settle(until: { spy.presenceChecks.count == 1 })
        #expect(engine.state == .normal)
        #expect(pet.returnSignals == 1)
    }

    @Test("メニューの在席スタンプの猶予中は疑い始めない")
    func stampGraceKeepsUsQuiet() async {
        let spy = ActionSpy()
        let attendance = AttendanceModel(
            store: AttendanceStore(defaults: emptyDefaults()),
            authenticator: AlwaysSucceedingAuthenticator()
        )
        await attendance.stamp()

        let engine = DetectionEngine(
            idleMonitor: MacIdleMonitor(probe: { 600 }),
            attendance: attendance,
            musicController: StubMusic()
        )
        engine.actions = spy.makeActions()
        engine.thresholds = .quick(stampGraceSeconds: 300)

        let decision = await engine.evaluate()

        #expect(decision.state == .normal)
        #expect(engine.state == .normal)
        #expect(spy.presenceChecks.isEmpty)
    }
}

/// テストごとに空の UserDefaults を用意する。在席の履歴をテスト同士で共有しない。
private func emptyDefaults() -> UserDefaults {
    let suiteName = "mihari.test.detection.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

/// 認証に必ず成功するスタブ。在席スタンプの猶予を作るのに使う。
private struct AlwaysSucceedingAuthenticator: TouchIDAuthenticating {
    private var available: TouchIDAvailability {
        TouchIDAvailability(canEvaluate: true, biometryType: .touchID, error: nil)
    }
    func biometricsAvailability() -> TouchIDAvailability { available }
    func deviceOwnerAvailability() -> TouchIDAvailability { available }
    func authenticate(policy: LAPolicy, reason: String) async -> TouchIDAuthenticationResult { .success }
    func cancelAuthentication() {}
}

/// 晒し(証拠の取り先・セリフ・投稿)だけを見る。
@Suite("晒し")
@MainActor
struct DetectionExposureTests {

    /// 疑い 3 まで進めてから晒す。
    private func exposeNow(
        spy: ActionSpy,
        pet: PetSpy? = nil,
        music: NowPlaying = .silent,
        iphone: SpeechRequest.IPhoneState = .unreachable,
        captureSucceeds: Bool = true
    ) async -> DetectionEngine {
        spy.captureSucceeds = captureSucceeds
        let engine = makeDetectionEngine(
            idle: IdleClock(600),
            spy: spy,
            pet: pet,
            music: music,
            iphone: iphone
        )
        engine.runDebugStep(.expose)
        // 晒しが終わるとメンヘラモードに入る。そこまで待つ。
        await settle(until: {
            if case .clingy = engine.state { return true }
            return false
        })
        return engine
    }

    @Test("iPhone から返事が無ければ、カメラで撮ってラベルを付ける")
    func unreachablePhoneUsesTheCamera() async {
        let spy = ActionSpy()
        let pet = PetSpy()
        let engine = await exposeNow(spy: spy, pet: pet)

        #expect(spy.macPhotos == 1)
        #expect(spy.iphoneShots == 0)
        #expect(spy.classified == 1)
        #expect(spy.posts.first?.filename == "camera.png")
        // 晒しのイベントにラベルが載る(そのあとメンヘラモードのイベントが続く)。
        #expect(pet.events.contains { $0.visionLabel == .asleep })
        #expect(engine.lastEvidenceAt != nil)
    }

    @Test("iPhone を触っていれば、画面を撮ってその中身に触れたセリフを作らせる")
    func activePhoneUsesTheScreenshot() async {
        let spy = ActionSpy()
        spy.speechSucceeds = true
        let pet = PetSpy()
        _ = await exposeNow(spy: spy, pet: pet, iphone: .active)

        #expect(spy.iphoneShots == 1)
        #expect(spy.macPhotos == 0)
        #expect(spy.spoken.first?.screenshotPNG == Data("iphone".utf8))
        #expect(pet.lines.contains("画面、見えてるよ。"))
        #expect(spy.posts.first?.filename == "iphone.png")
    }

    @Test("セリフを作れなければ同封音声に倒し、文面のためだけに画面を読ませる")
    func fallsBackToBundledLineButStillReadsTheScreen() async {
        let spy = ActionSpy()
        spy.speechSucceeds = false
        let pet = PetSpy()
        _ = await exposeNow(spy: spy, pet: pet, iphone: .active)

        #expect(spy.screenReads.count == 1)
        let line = pet.lines.last ?? ""
        #expect(BundledVoiceLines.shared.lines(for: .iphoneActive).contains(line))
        // 読み取れた内容が投稿の 1 行目に出る。
        #expect(spy.posts.first?.text.contains("YouTube") == true)
    }

    @Test("音楽が鳴っているときだけ画面を奪う")
    func interruptsOnlyWhenMusicIsPlaying() async {
        let quiet = ActionSpy()
        _ = await exposeNow(spy: quiet)
        #expect(quiet.interrupted.isEmpty)

        let loud = ActionSpy()
        _ = await exposeNow(spy: loud, music: .playing(.spotify))
        #expect(loud.interrupted.count == 1)
        #expect(loud.interrupted.first?.escalation == .expose)
    }

    @Test("撮れなくても送信を試みず、メンヘラモードには進む")
    func captureFailureStillEntersClingy() async {
        let spy = ActionSpy()
        let engine = await exposeNow(spy: spy, captureSucceeds: false)

        #expect(spy.macPhotos == 1)
        #expect(spy.posts.isEmpty)
        #expect(engine.lastEvidenceAt == nil)
        #expect(engine.log.contains { $0.outcome.contains("証拠を取れなかった") })
        if case .clingy = engine.state {} else { Issue.record("メンヘラモードに入っていない") }
    }

    @Test("送れなくても記録には残り、メンヘラモードには進む")
    func postFailureIsRecorded() async {
        let spy = ActionSpy()
        spy.postSucceeds = false
        let engine = await exposeNow(spy: spy)

        #expect(engine.log.contains { $0.outcome.contains("送れなかった") })
        if case .clingy = engine.state {} else { Issue.record("メンヘラモードに入っていない") }
    }

    @Test("Discord には reason ではなく組み立てた本文をメンション付きで送る")
    func postsComposedMessage() async {
        let spy = ActionSpy()
        let engine = await exposeNow(spy: spy)

        let posted = spy.posts.first
        #expect(posted?.text.contains(DiscordMessageComposer.subtextPrefix) == true)
        #expect(posted?.mention == true)
        #expect(engine.log.contains { $0.reason.isEmpty == false })
    }
}
