import Foundation
import Testing

@testable import MihariCore

/// 実行部が何を呼ばれたかを記録するスパイ。
/// `@Sendable` クロージャから触るのでロックで守る。
final class ActionSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _macPhotos = 0
    private var _iphoneShots = 0
    private var _spoken: [SpeechRequest] = []
    private var _interrupted: [SpeechRequest] = []
    private var _posts: [(String, Data?, String)] = []
    private var _classified = 0

    var macPhotos: Int { lock.withLock { _macPhotos } }
    var iphoneShots: Int { lock.withLock { _iphoneShots } }
    var spoken: [SpeechRequest] { lock.withLock { _spoken } }
    var interrupted: [SpeechRequest] { lock.withLock { _interrupted } }
    var posts: [(String, Data?, String)] { lock.withLock { _posts } }
    var classified: Int { lock.withLock { _classified } }

    /// 撮影が失敗する状況を作るためのつまみ。
    var captureSucceeds = true
    /// 送信が失敗する状況を作るためのつまみ。
    var postSucceeds = true

    func makeActions() -> DetectionEngine.Actions {
        DetectionEngine.Actions(
            captureMacPhoto: { [self] in
                lock.withLock { _macPhotos += 1 }
                return captureSucceeds ? Data("camera".utf8) : nil
            },
            captureIPhoneScreenshot: { [self] in
                lock.withLock { _iphoneShots += 1 }
                return captureSucceeds ? Data("iphone".utf8) : nil
            },
            speak: { [self] request in
                lock.withLock { _spoken.append(request) }
                return "喋った"
            },
            interrupt: { [self] request in
                lock.withLock { _interrupted.append(request) }
            },
            post: { [self] text, image, filename in
                lock.withLock { _posts.append((text, image, filename)) }
                return postSucceeds
            },
            classify: { [self] _ in
                lock.withLock { _classified += 1 }
                return .sleeping
            }
        )
    }
}

@Suite("検知エンジン")
@MainActor
struct DetectionEngineTests {

    private func engine(idle: TimeInterval, spy: ActionSpy) -> DetectionEngine {
        let engine = DetectionEngine(
            idleMonitor: MacIdleMonitor(probe: { idle }),
            frontmostMonitor: FrontmostAppMonitor(probe: { "Safari" })
        )
        engine.actions = spy.makeActions()
        return engine
    }

    @Test("触っている間は何も呼ばれない")
    func normalDoesNothing() async {
        let spy = ActionSpy()
        let engine = engine(idle: 10, spy: spy)

        let decision = await engine.evaluate()

        #expect(decision.state == .normal)
        #expect(spy.macPhotos == 0)
        #expect(spy.spoken.isEmpty)
        #expect(spy.posts.isEmpty)
        #expect(engine.log.isEmpty)
    }

    @Test("疑いの段階では喋るだけで、撮らないし送らない")
    func suspectedOnlySpeaks() async {
        let spy = ActionSpy()
        let engine = engine(idle: 150, spy: spy)

        await engine.evaluate()

        #expect(spy.spoken.count == 1)
        #expect(spy.spoken.first?.escalation == .nudge)
        #expect(spy.macPhotos == 0)
        #expect(spy.posts.isEmpty)
    }

    @Test("確定 × iPhone 応答なし → カメラで撮って送る")
    func confirmedUnreachableCapturesCamera() async {
        let spy = ActionSpy()
        let engine = engine(idle: 600, spy: spy)
        engine.iphoneState = .unreachable

        await engine.evaluate()

        #expect(spy.macPhotos == 1)
        #expect(spy.iphoneShots == 0)
        #expect(spy.posts.count == 1)
        #expect(spy.posts.first?.2 == "camera.png")
    }

    @Test("確定 × iPhone 操作中 → iPhone のスクショを撮って送る")
    func confirmedActivePhoneCapturesScreenshot() async {
        let spy = ActionSpy()
        let engine = engine(idle: 600, spy: spy)
        engine.iphoneState = .active

        await engine.evaluate()

        #expect(spy.iphoneShots == 1)
        #expect(spy.macPhotos == 0)
        #expect(spy.posts.first?.2 == "iphone.png")
    }

    @Test("Vision のラベル付けはカメラ写真のときだけ走る")
    func visionRunsOnlyForCameraPhotos() async {
        // iPhone の画面に顔は写らない。無駄に走らせない。
        let spy = ActionSpy()
        let engine = engine(idle: 600, spy: spy)
        engine.iphoneState = .active

        await engine.evaluate()

        #expect(spy.classified == 0)
    }

    @Test("カメラ写真にはラベルが付いてセリフに渡る")
    func visionLabelReachesTheLine() async {
        let spy = ActionSpy()
        let engine = engine(idle: 600, spy: spy)
        engine.iphoneState = .unreachable

        await engine.evaluate()

        #expect(spy.classified == 1)
        #expect(spy.interrupted.first?.vision == .sleeping)
    }

    @Test("確定すると音楽を止めて聞かせる")
    func confirmedInterrupts() async {
        let spy = ActionSpy()
        let engine = engine(idle: 600, spy: spy)

        await engine.evaluate()

        #expect(spy.interrupted.count == 1)
        #expect(spy.interrupted.first?.escalation == .expose)
        // 割り込んだときは普通の発話はしない。二重に喋らせない。
        #expect(spy.spoken.isEmpty)
    }

    @Test("撮れなくても送信を試みず、評価は続く")
    func captureFailureDoesNotPost() async {
        let spy = ActionSpy()
        spy.captureSucceeds = false
        let engine = engine(idle: 600, spy: spy)

        await engine.evaluate()

        #expect(spy.macPhotos == 1)
        #expect(spy.posts.isEmpty)
        #expect(engine.log.first?.outcome.contains("取れなかった") == true)
    }

    @Test("送れなくても記録には残る")
    func postFailureIsRecorded() async {
        let spy = ActionSpy()
        spy.postSucceeds = false
        let engine = engine(idle: 600, spy: spy)

        await engine.evaluate()

        #expect(engine.log.first?.outcome.contains("送れなかった") == true)
    }

    @Test("直前に撮っていれば撮り直さない")
    func cooldownPreventsRepeatedCapture() async {
        // これが無いと 5 秒ごとに撮って送り続けることになる。
        let spy = ActionSpy()
        let engine = engine(idle: 600, spy: spy)

        await engine.evaluate()
        await engine.evaluate()

        #expect(spy.macPhotos == 1)
        #expect(spy.posts.count == 1)
    }

    @Test("判断の根拠と結果が必ず記録される")
    func everyDecisionIsLogged() async {
        let spy = ActionSpy()
        let engine = engine(idle: 600, spy: spy)

        await engine.evaluate()

        let entry = engine.log.first
        #expect(entry?.state == .confirmed)
        #expect(entry?.evidence == .macCamera)
        #expect(entry?.reason.isEmpty == false)
        #expect(entry?.outcome.isEmpty == false)
    }

    @Test("記録は上限を超えると古いものから消える")
    func logIsCapped() async {
        let spy = ActionSpy()
        let engine = engine(idle: 150, spy: spy)

        for _ in 0...(DetectionEngine.logHistoryLimit + 3) {
            await engine.evaluate()
        }

        #expect(engine.log.count == DetectionEngine.logHistoryLimit)
    }

    @Test("止めると監視状態が戻る")
    func stopResetsState() async {
        let spy = ActionSpy()
        let engine = engine(idle: 600, spy: spy)
        engine.start()
        #expect(engine.isWatching)

        engine.stop()

        #expect(engine.isWatching == false)
        #expect(engine.state == .normal)
    }

    @Test("閾値を差し替えると判定も変わる")
    func thresholdsApply() async {
        let spy = ActionSpy()
        let engine = engine(idle: 30, spy: spy)
        engine.thresholds = DetectionThresholds(suspectSeconds: 10, confirmSeconds: 20)

        let decision = await engine.evaluate()

        #expect(decision.state == .confirmed)
    }

    @Test("材料には前面アプリ名が入る")
    func signalsCarryFrontmostApp() async {
        let spy = ActionSpy()
        let engine = engine(idle: 600, spy: spy)

        await engine.evaluate()

        #expect(engine.lastSignals?.frontmostApp == "Safari")
        #expect(spy.interrupted.first?.frontmostApp == "Safari")
    }
}
