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

/// デバッグメニューの「メンヘラを始める」。押したら確定で 5 回投げる。
@Suite("メンヘラの連投(デバッグ)")
@MainActor
struct DetectionClingyBurstTests {

    /// 連投の待ちを外から開ける門。閉じているあいだ、連投は次の 1 件へ進まない。
    private final class BurstGate: @unchecked Sendable {
        private let lock = NSLock()
        private var _closed = true

        var isClosed: Bool { lock.withLock { _closed } }
        func open() { lock.withLock { _closed = false } }
    }

    @Test("Mac を触っていても、テキストだけの投稿を 5 回続けて投げる")
    func burstPostsFiveTimes() async {
        let spy = ActionSpy()
        let pet = PetSpy()
        // 無操作 0 秒＝Mac を触っている。それでも連投は止まらない。
        let engine = makeDetectionEngine(idle: IdleClock(0), spy: spy, pet: pet, sleep: { _ in })

        engine.runDebugStep(.startClingy)
        await settle(until: { spy.posts.count == DetectionEngine.debugClingyBurstCount })

        #expect(spy.posts.count == 5)
        #expect(spy.posts.allSatisfy { $0.mention })
        #expect(spy.posts.allSatisfy { $0.filename == "evidence.png" })
        #expect(spy.posts.allSatisfy { $0.image == nil })
        #expect(spy.posts.allSatisfy { $0.text.contains("戻ってこないまま") })

        guard case .clingy(_, let count) = engine.state else {
            Issue.record("メンヘラモードのままになっていない")
            return
        }
        #expect(count == DetectionEngine.debugClingyBurstCount)
        #expect(engine.escalationStage == PetEvent.clingyStage)
    }

    @Test("連投の途中で評価が走っても、「戻ってきた」投稿は挟まらない")
    func evaluatingDuringBurstDoesNotFinish() async {
        let spy = ActionSpy()
        let gate = BurstGate()
        let engine = makeDetectionEngine(
            idle: IdleClock(0),
            spy: spy,
            sleep: { _ in
                // 門が開くまで連投を止めて、途中の状態を確かめられるようにする。
                while gate.isClosed { try? await Task.sleep(for: .milliseconds(1)) }
            }
        )

        engine.runDebugStep(.startClingy)
        await settle(until: { spy.posts.count == 1 })

        // Mac を触っているので、素通しなら「戻ってきた」投稿が挟まる。
        let decision = await engine.evaluate()
        #expect(decision.reason == "メンヘラの連投中")
        #expect(spy.posts.count == 1)

        gate.open()
        await settle(until: { spy.posts.count == DetectionEngine.debugClingyBurstCount })

        #expect(spy.posts.count == 5)
        #expect(spy.posts.allSatisfy { $0.mention })
        #expect(spy.posts.allSatisfy { $0.text != DetectionEngine.fallbackReturnedLine })
    }
}

/// デバッグメニューの「今すぐ Touch ID 確認 / 首振り確認」。
/// メニューをクリックした操作そのものが Mac の入力なので、素通しだと数秒で畳まれてしまう。
@Suite("デバッグの確認は Mac を触っていても畳まない")
@MainActor
struct DetectionDebugCheckTests {

    /// 確認の決着を外から起こす門。閉じているあいだ、Touch ID は決着しない。
    private final class CheckGate: @unchecked Sendable {
        private let lock = NSLock()
        private var _closed = true

        var isClosed: Bool { lock.withLock { _closed } }
        func open() { lock.withLock { _closed = false } }
    }

    /// 無操作 0 秒(＝Mac を触っている)のまま首振り確認を出す。
    private func startHeadGestureCheck(pet: PetSpy, spy: ActionSpy = ActionSpy()) async -> DetectionEngine {
        let engine = makeDetectionEngine(idle: IdleClock(0), spy: spy, pet: pet)
        engine.runDebugStep(.headGestureCheck)
        await settle(until: { pet.prompts.count == 1 })
        return engine
    }

    @Test("首振り確認は、Mac を触っていても問いかけが残る")
    func headGestureCheckSurvivesInput() async {
        let pet = PetSpy()
        let engine = await startHeadGestureCheck(pet: pet)

        let decision = await engine.evaluate()

        #expect(decision.reason == "デバッグの確認中")
        #expect(engine.state == .suspect(stage: 2))
        #expect(pet.prompts.count == 1)
        #expect(pet.dismissals == 0)
    }

    @Test("うなずけば決着して正常に戻り、その先は通常のルールに戻る")
    func nodSettlesTheDebugCheck() async throws {
        let pet = PetSpy()
        let engine = await startHeadGestureCheck(pet: pet)
        let prompt = try #require(pet.prompts.first)

        prompt.onAnswer(true)
        await settle(until: { engine.state == .normal })

        #expect(engine.state == .normal)
        #expect(pet.dismissals == 1)

        let decision = await engine.evaluate()
        #expect(decision.reason != "デバッグの確認中")
        #expect(decision.state == .normal)
    }

    @Test("首を横に振れば疑い 2 のまま。そのあとは Mac を触っていれば正常に戻る")
    func shakeSettlesAndLetsTheNormalRuleBack() async throws {
        let pet = PetSpy()
        let engine = await startHeadGestureCheck(pet: pet)
        let prompt = try #require(pet.prompts.first)

        prompt.onAnswer(false)
        await settle(until: { pet.dismissals == 1 })
        #expect(engine.state == .suspect(stage: 2))

        // 決着したので、ここからは通常どおり「戻ってきた」で畳まれる。
        let decision = await engine.evaluate()
        #expect(decision.reason == "疑い 2 回目の途中で戻ってきた")
        #expect(engine.state == .normal)
    }

    @Test("Touch ID 確認も、決着するまで Mac の入力で畳まない")
    func touchIDCheckSurvivesInput() async {
        let spy = ActionSpy()
        let gate = CheckGate()
        let engine = makeDetectionEngine(idle: IdleClock(0), spy: spy)
        engine.actions.confirmPresence = { _ in
            // 門が開くまで決着させず、途中の状態を確かめられるようにする。
            while gate.isClosed { try? await Task.sleep(for: .milliseconds(1)) }
            return .stamped
        }

        engine.runDebugStep(.touchIDCheck)
        await settle(until: { engine.isCheckRunning })

        let decision = await engine.evaluate()
        #expect(decision.reason == "デバッグの確認中")
        #expect(engine.state == .suspect(stage: 1))
        #expect(spy.presenceCancels == 0)

        gate.open()
        await settle(until: { engine.state == .normal })
        #expect(engine.state == .normal)
    }

    @Test("監視を止めれば、デバッグの確認中でも問いかけは畳まれる")
    func stopFoldsTheDebugCheck() async {
        let pet = PetSpy()
        let engine = await startHeadGestureCheck(pet: pet)

        engine.stop()

        #expect(engine.state == .normal)
        #expect(pet.dismissals == 1)
    }
}
