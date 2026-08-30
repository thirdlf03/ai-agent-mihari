import Foundation

@testable import MihariCore

/// 無操作秒数を外から動かせる箱。`@Sendable` クロージャから読むのでロックで守る。
final class IdleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ seconds: TimeInterval = 0) { value = seconds }

    func set(_ seconds: TimeInterval) { lock.withLock { value = seconds } }
    func read() -> TimeInterval { lock.withLock { value } }
}

/// 実行部が何を呼ばれたかを記録するスパイ。
/// `@Sendable` クロージャから触るのでロックで守る。
final class ActionSpy: @unchecked Sendable {
    /// 1 件の投稿。本文 / 画像 / ファイル名 / メンションを付けたか。
    struct Post: Sendable {
        let text: String
        let image: Data?
        let filename: String
        let mention: Bool
    }

    private let lock = NSLock()
    private var _macPhotos = 0
    private var _iphoneShots = 0
    private var _spoken: [SpeechRequest] = []
    private var _interrupted: [SpeechRequest] = []
    private var _posts: [Post] = []
    private var _classified = 0
    private var _screenReads: [SpeechRequest] = []
    private var _presenceChecks: [Bool] = []
    private var _presenceCancels = 0

    var macPhotos: Int { lock.withLock { _macPhotos } }
    var iphoneShots: Int { lock.withLock { _iphoneShots } }
    var spoken: [SpeechRequest] { lock.withLock { _spoken } }
    var interrupted: [SpeechRequest] { lock.withLock { _interrupted } }
    var posts: [Post] { lock.withLock { _posts } }
    var classified: Int { lock.withLock { _classified } }
    var screenReads: [SpeechRequest] { lock.withLock { _screenReads } }
    /// Touch ID チェックを頼まれた回数と、そのときの「iPhone を触っているか」。
    var presenceChecks: [Bool] { lock.withLock { _presenceChecks } }
    var presenceCancels: Int { lock.withLock { _presenceCancels } }

    /// 撮影が失敗する状況を作るためのつまみ。
    var captureSucceeds = true
    /// 送信が失敗する状況を作るためのつまみ。
    var postSucceeds = true
    /// bridge にセリフを作らせられるか。既定は作れない(＝同封セリフに倒れる)。
    var speechSucceeds = false
    /// Touch ID チェックの結末。
    var presenceOutcome: AttendanceStampOutcome = .timedOut
    /// 画面読み取りが返す内容。`nil` なら読めなかったことにする。
    var screenReading: SpokenLine.ScreenReading? = SpokenLine.ScreenReading(
        app: "YouTube",
        activity: "動画を見ている",
        category: "slacking"
    )

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
                guard speechSucceeds else { return nil }
                return SpokenSpeech(text: "画面、見えてるよ。", screen: screenReading)
            },
            readScreen: { [self] request in
                lock.withLock { _screenReads.append(request) }
                return ScreenReadResult(screen: screenReading)
            },
            interrupt: { [self] request in
                lock.withLock { _interrupted.append(request) }
            },
            post: { [self] text, image, filename, mention in
                lock.withLock {
                    _posts.append(Post(text: text, image: image, filename: filename, mention: mention))
                }
                return postSucceeds
            },
            classify: { [self] _ in
                lock.withLock { _classified += 1 }
                return .sleeping
            },
            confirmPresence: { [self] onPhone in
                lock.withLock { _presenceChecks.append(onPhone) }
                return presenceOutcome
            },
            cancelPresenceCheck: { [self] in
                lock.withLock { _presenceCancels += 1 }
            }
        )
    }
}

/// ペットに届いたイベントと、問いかけを引っ込めた回数を溜める箱。
final class PetSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [PetEvent] = []
    private var _dismissals = 0

    var events: [PetEvent] { lock.withLock { _events } }
    var dismissals: Int { lock.withLock { _dismissals } }
    /// 問いかけの付いたイベントだけ。
    var prompts: [PetYesNoPrompt] { events.compactMap(\.prompt) }
    /// セリフの無い正常イベント(＝「おかえり」の合図)の数。
    var returnSignals: Int { events.filter { $0.state == .normal && $0.line.isEmpty }.count }
    /// 空でないセリフだけを届いた順に。
    var lines: [String] { events.map(\.line).filter { !$0.isEmpty } }

    func record(_ event: PetEvent) { lock.withLock { _events.append(event) } }
    func recordDismissal() { lock.withLock { _dismissals += 1 } }
}

/// 音楽の有無を固定するスタブ。AppleScript を実際に投げさせない。
struct StubMusic: MusicControlling {
    let playing: NowPlaying

    init(playing: NowPlaying = .silent) { self.playing = playing }

    func nowPlaying() async -> NowPlaying { playing }
    func stopPlaying() async -> MusicStopOutcome { .nothingWasPlaying }
    func resumePlaying(_ outcome: MusicStopOutcome) async {}
}

extension DetectionThresholds {
    /// 本番想定の値。`.default` は `MIHARI_FAST_THRESHOLDS` で揺れるので、テストはこちらを使う。
    static let production = DetectionThresholds()

    /// テストで一連の流れを回すための、秒単位まで縮めた値。
    ///
    /// 問いかけの待ちは既定で長くしてある。時間切れを見たいテストだけ `sleep` を潰す。
    static func quick(
        suspectSeconds: TimeInterval = 10,
        stageIntervalSeconds: TimeInterval = 5,
        promptTimeoutSeconds: TimeInterval = 100,
        clingyIntervalSeconds: TimeInterval = 20,
        clingyEvidenceIntervalSeconds: TimeInterval = 100,
        breakDurationSeconds: TimeInterval = 900,
        stampGraceSeconds: TimeInterval = 0
    ) -> DetectionThresholds {
        DetectionThresholds(
            suspectSeconds: suspectSeconds,
            stageIntervalSeconds: stageIntervalSeconds,
            promptTimeoutSeconds: promptTimeoutSeconds,
            clingyIntervalSeconds: clingyIntervalSeconds,
            clingyEvidenceIntervalSeconds: clingyEvidenceIntervalSeconds,
            breakDurationSeconds: breakDurationSeconds,
            stampGraceSeconds: stampGraceSeconds
        )
    }
}

/// 検知エンジンをテスト用に組み立てる。OS には一切触らせない。
@MainActor
func makeDetectionEngine(
    idle: IdleClock,
    spy: ActionSpy,
    pet: PetSpy? = nil,
    thresholds: DetectionThresholds = .quick(),
    music: NowPlaying = .silent,
    frontmostApp: String? = "Xcode",
    iphone: SpeechRequest.IPhoneState = .unreachable,
    headGesture: (@Sendable (String, TimeInterval) async -> HeadGestureResponse)? = nil,
    sleep: @escaping DetectionEngine.Sleeping = { try? await Task.sleep(for: $0) }
) -> DetectionEngine {
    let engine = DetectionEngine(
        idleMonitor: MacIdleMonitor(probe: { idle.read() }),
        frontmostMonitor: FrontmostAppMonitor(probe: { frontmostApp }),
        musicController: StubMusic(playing: music),
        sleep: sleep
    )
    var actions = spy.makeActions()
    if let headGesture { actions.askHeadGesture = headGesture }
    engine.actions = actions
    engine.thresholds = thresholds
    engine.iphoneState = iphone
    if let pet {
        engine.onEvent = { pet.record($0) }
        engine.onPromptDismissed = { pet.recordDismissal() }
    }
    return engine
}

/// 別タスクの決着を待つ。実時間で決め打ちすると、並列実行時の混雑で簡単にフラフラになる。
@MainActor
func settle(until condition: () -> Bool) async {
    for _ in 0..<500 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
}
