import AppKit
import Combine
import Foundation
import SwiftUI

/// アプリ全体の取りまとめ役。
///
/// ここが唯一「全機能を知っている」場所。各機能は互いを知らずに作ってあり、
/// 検知エンジンの実行部にそれぞれを差し込むことで初めて 1 つのアプリになる。
/// 画面(ペット・補助ウィンドウ・メニュー)からの操作もすべてここを通る。
@MainActor
public final class AppCoordinator: ObservableObject, PetMenuActions {

    /// 検証用の 10 タブ画面を出すかどうかを決める環境変数。
    static let debugUIEnvironmentKey = "MIHARI_DEBUG_UI"

    public let permissions: PermissionsModel
    public let daemon = DaemonController()
    public let voice: VoiceController
    /// 同封音声か live か。ペット・検知・説教のすべてがここを見る。
    public let voiceModeStore: VoiceModeStore
    public let discord = DiscordController()
    public let attendance: AttendanceModel
    public let detection: DetectionEngine
    public let pet: LivePetPresenter
    public let questioner = HeadGestureQuestioner()

    /// 音楽を止めて聞かせる全画面オーバーレイ。
    ///
    /// セリフの取得と読み上げを注入するため、`self` を参照できる `lazy var` にしてある。
    /// 注入しないと、音楽が鳴っている場面(`interrupt` 経路)で一言も喋らないまま暗転する。
    public lazy var overlay: OverlayModel = makeOverlay()

    // 以下は検証用の 10 タブ画面でしか使わないので、開かれるまで作らない。
    public lazy var capture = CaptureViewModel(
        iphoneScreenshot: { [daemon] in
            guard let client = await daemon.connectedClient else { throw DaemonError.notRunning }
            return try await client.iphoneScreenshot()
        },
        speak: { [voice, daemon] request in
            // 喋れなかったときに前回の記録を返してしまわないよう、成否を先に見る。
            guard await voice.speak(request, using: daemon.connectedClient) != nil else { return nil }
            return voice.history.first
        }
    )
    public lazy var vision = FaceVisionViewModel()
    public lazy var headGesture = HeadGestureController()

    /// 監視中か。メニューの表示に使う。
    @Published public private(set) var isWatching = false
    /// 休憩中か。メニューの表示に使う。
    @Published public private(set) var isOnBreak = false
    /// 状態パネルを出しているか。メニューの表示に使う。
    @Published public private(set) var isStatusPanelVisible = false

    /// 在席スタンプのカットインを出す層。
    private let cutIn: AttendanceCutInPresenting = AttendanceCutInPresenter()
    /// 在席スタンプ / 疑い 1 の演出をしている最中か。押し直しでカットインが重なるのを防ぐ。
    private var isStampCeremonyRunning = false
    /// 演出の世代。畳まれたら 1 つ進めて、結末の演出を出さずにカットインだけ閉じる。
    private var ceremonyGeneration = 0

    /// カットインを出してから認証ダイアログを出すまでの間(秒)。
    private static let cutInLeadInSeconds: TimeInterval = 0.45
    /// 結末の絵に差し替えてからカットインを閉じるまでの時間(秒)。
    private static let cutInHoldSeconds: TimeInterval = 1.8

    /// 音を出す口。検知のセリフとペットのひとりごとで 1 つを共有する。
    private let speechPlayer: SpeechPlayer
    /// アプリの外(Claude Code のフックなど)からの合図の受け口。
    private let externalTrigger = ExternalTriggerListener()
    private let windows = AuxiliaryWindows()
    private let statusPanel = StatusPanelController()
    /// 監視中はディスプレイ/システムのアイドルスリープを止める。
    private let sleepPreventer: SleepPreventing
    /// 起動してから何時間かは終了そのものを受け付けない。
    private var quitTimeLock = QuitTimeLock()
    /// `quitTimeLock` に渡す既定のロック時間。デーモン(Discord の `/watch lock`)から
    /// 取れなかったときのフォールバック。
    private static let defaultLockHours: Double = 4
    /// kill されて落ちても次回ログインで自動的に立ち上がるよう登録する。
    private let loginItemRegistrar: LoginItemRegistering
    /// 本体が kill されても、こちらの監視プロセスが数秒以内に起こす。
    private let watchdogRegistrar: WatchdogRegistering
    /// 前回、正常に終了できていたか(kill されて起こされたのかを見分けるため)。
    private let lifecycleMarker: AppLifecycleMarking
    private var cancellables: Set<AnyCancellable> = []
    /// すでに見張り始めたか。`begin()` を何度呼んでも 1 回しか効かないようにする。
    private var hasBegun = false
    /// 監視プロセスの登録を定期的に見直すループ。`launchctl bootout` で外から
    /// 消されても、Touch ID を経ずには長続きさせないためのもの。
    private var watchdogReassertionTask: Task<Void, Never>?
    /// 上の見直しの間隔。短すぎると無駄に `launchctl` を叩き、長すぎると
    /// 「外から消されてから戻るまで」のすきまが意味を持ち始める。
    private static let watchdogReassertionInterval: Duration = .seconds(20)

    /// - Parameters:
    ///   - sleepPreventer: スリープ防止の実体。テストでは呼び出し回数だけ記録するスタブに差し替える。
    ///   - loginItemRegistrar: ログイン項目への登録処理。テストでは何もしないスタブに差し替える。
    ///   - watchdogRegistrar: 監視プロセスの登録処理。テストでは何もしないスタブに差し替える。
    ///   - lifecycleMarker: 前回の終了が正常だったかの記録。テストでは固定値を返すスタブに差し替える。
    public init(
        sleepPreventer: SleepPreventing = IOPMSleepPreventer(),
        loginItemRegistrar: LoginItemRegistering = SMAppServiceLoginItemRegistrar(),
        watchdogRegistrar: WatchdogRegistering = LaunchAgentWatchdogRegistrar(),
        lifecycleMarker: AppLifecycleMarking = UserDefaultsLifecycleMarker()
    ) {
        let player = SpeechPlayer()
        let attendance = AttendanceModel()
        self.speechPlayer = player
        self.attendance = attendance
        self.permissions = PermissionsModel()
        self.voice = VoiceController(player: player)
        self.voiceModeStore = VoiceModeStore()
        // 在席スタンプ直後の猶予を効かせるため、検知エンジンに在席の記録を渡す。
        self.detection = DetectionEngine(attendance: attendance)
        self.pet = LivePetPresenter(controller: PetController(speechPlayer: player))
        self.isStatusPanelVisible = statusPanel.isVisible
        self.sleepPreventer = sleepPreventer
        self.loginItemRegistrar = loginItemRegistrar
        self.watchdogRegistrar = watchdogRegistrar
        self.lifecycleMarker = lifecycleMarker
        observeVoiceMode()
    }

    /// 音声モードの切り替えを、喋る側すべてに配る。
    ///
    /// メニューから切り替えた瞬間に効かせたいので、`@Published` を購読して押し込む。
    private func observeVoiceMode() {
        voiceModeStore.$mode
            .sink { [weak self] mode in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // 検知のセリフは同封音声で固定なので、切り替えるのはペットのひとりごとと説教。
                    self.pet.controller.voiceMode = mode
                    // メニューバー側のチェックを描き直させる。
                    self.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - 起動

    /// 起動直後に一度だけ呼ぶ。権限が揃っているかで、権限画面を出すか見張り始めるかを決める。
    public func launch() {
        permissions.refresh()

        if Self.isDebugUIRequested {
            showDebugWindow()
        }

        // 初回起動、または必須権限が欠けているうちは見張らない。
        // 撮れも送れもしない状態で常駐しても、黙って失敗し続けるだけになる。
        if !permissions.hasCompletedFirstLaunch || !permissions.isRequiredSatisfied {
            showPermissionWindow(canStart: true)
        } else {
            begin()
        }
    }

    /// ペットを出して見張り始める。2 回目以降は何もしない。
    public func begin() {
        guard !hasBegun else { return }
        hasBegun = true

        // 見張っている間は画面が暗転して撮影・検知が止まらないよう、スリープを止める。
        sleepPreventer.start()
        // kill されて落ちても次回ログインで自動的に立ち上がるようにする。
        loginItemRegistrar.ensureRegistered()
        // 本体が kill されても、監視プロセスが数秒以内に起こす。
        watchdogRegistrar.ensureRegistered()
        // `launchctl bootout` で監視プロセスの登録だけ外からむしり取られても、
        // Touch ID を経ない解除を長続きさせない。
        watchdogReassertionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchdogReassertionInterval)
                guard !Task.isCancelled else { return }
                self?.watchdogRegistrar.reassertIfMissing()
            }
        }

        // 前回、正常に終了できていなければ(= kill か crash で消えたのを監視プロセスに
        // 起こされたのなら)、記録を上書きする前に見ておく。
        let wasKilled = !lifecycleMarker.wasPreviousSessionGraceful()
        lifecycleMarker.markSessionStarted()

        // 右クリックメニューはウィンドウを作る前に差し込む。
        pet.controller.contextMenuBuilder = { [weak self] in
            guard let self else { return NSMenu() }
            return PetContextMenu.makeMenu(PetMenuEntries.make(actions: self, presenter: pet))
        }
        pet.show()
        if wasKilled {
            pet.controller.say(RevivalAngerLine.random())
        }
        statusPanel.restore { statusPanelView }
        observeDetection()
        observeDaemonEvents()

        // Claude Code の Stop フック(notifyutil -p)からの「応答を終えた」合図。
        externalTrigger.listen(name: ExternalTriggerListener.claudeDoneName) { [weak self] in
            Task { @MainActor [weak self] in
                self?.pet.controller.say("終わったよー")
            }
        }

        Task { [weak self] in
            guard let self else { return }
            await daemon.start()
            wireDetection()
            // 常駐して見張るアプリなので、始めたら見張り続ける。
            detection.start()

            // ロック時間は Discord の `/watch lock` で決まる。デーモンに繋がる前に
            // 決め打ちすると設定より短く/長くロックしてしまうので、繋がってから引く。
            // 取れなければ既定値で必ずロックする ―― 取れないからロックしない、は
            // 「ロックできない状況を作れば終了できる」という抜け道になってしまう。
            var hours: Double?
            if let client = daemon.connectedClient {
                hours = try? await client.lockHours()
            }
            quitTimeLock.lock(for: hours ?? Self.defaultLockHours)
        }
    }

    /// 終了時の後片付け。見張りを止めて、子プロセスのデーモンも落とす。
    public func shutdown() {
        detection.stop()
        daemon.stop()
        sleepPreventer.stop()
        watchdogReassertionTask?.cancel()
        watchdogReassertionTask = nil
    }

    /// 終了(Cmd+Q・Dock「終了」・kill によるシグナル)してよいか。
    ///
    /// 見張り始める前(権限オンボーディング中)はまだロックする意味がないので素通しする。
    /// ロックが解けていれば、監視プロセスとログイン項目の登録もここで解く ―― 解かずに
    /// 本体だけ終了させると、監視プロセスが「本体が消えた」と誤解してまた起こしてしまう。
    ///
    /// ロック中は、認証のふりをして結果を無視するようなことは一切しない。
    /// 単に断り、あと何分ロックが残っているかをペットに正直に言わせるだけ。
    public func confirmQuit() async -> Bool {
        guard hasBegun else { return true }
        guard quitTimeLock.isUnlocked() else {
            if let remaining = quitTimeLock.remainingDescription() {
                pet.controller.say("まだロック中。\(remaining)は消せないよ。")
            }
            return false
        }
        watchdogRegistrar.unregister()
        loginItemRegistrar.unregister()
        lifecycleMarker.markGracefulShutdown()
        return true
    }

    /// Dock のアイコンがクリックされた。
    ///
    /// - Returns: AppKit に既定の処理(ウィンドウを開き直す)を続けさせるか。
    ///   見張り始めたあとはペットを出すだけで、ウィンドウは開かない。
    public func handleReopen() -> Bool {
        guard hasBegun else { return true }
        pet.show()
        return false
    }

    /// 検証用の 10 タブ画面が要求されているか。
    private static var isDebugUIRequested: Bool {
        ProcessInfo.processInfo.environment[debugUIEnvironmentKey] == "1"
    }

    // MARK: - ウィンドウ

    /// 権限の確認画面を出す。
    ///
    /// - Parameter canStart: まだ見張り始めていないなら true。「始める」ボタンを出す。
    ///   すでに見張っているときは押す意味がないので「閉じる」にする。
    private func showPermissionWindow(canStart: Bool) {
        windows.showPermissions {
            if canStart {
                OnboardingView(
                    model: permissions,
                    onStart: { [weak self] in
                        guard let self else { return }
                        windows.closePermissions()
                        begin()
                    }
                )
            } else {
                OnboardingView(
                    model: permissions,
                    onClose: { [weak self] in self?.windows.closePermissions() }
                )
            }
        }
    }

    private func showDebugWindow() {
        windows.showDebug { RootView(coordinator: self) }
    }

    // MARK: - PetMenuActions

    public func startWatching() {
        // 「監視を再開する」を押した相手を休憩中のまま放置しない。
        if isOnBreak { detection.endBreak() }
        detection.start()
    }

    public func stopWatching() {
        // 休憩には触れない。休憩と監視の開始 / 停止は別の話。
        detection.stop()
    }

    /// 在席スタンプを押す。ペットが指を差し出し、Touch ID に指を置いて「指を合わせる」演出にする。
    ///
    /// 演出中に押し直されても何もしない。カットインが二重に出てしまうため。
    /// 押した時点で「いま席にいる」と示されたことになるので、進んでいた疑いはここで畳む。
    public func stampAttendance() {
        detection.acknowledgePresence()
        guard !isStampCeremonyRunning else { return }
        isStampCeremonyRunning = true
        Task { [weak self] in
            guard let self else { return }
            await runCeremony(.stamp)
            isStampCeremonyRunning = false
        }
    }

    /// 疑い 1 の Touch ID チェック。在席スタンプと同じ演出を、疑い用のセリフで流す。
    ///
    /// 成功しても履歴には残さない(`verify()`)。促されて置いた指で 5 分間見逃されては
    /// チェックの意味が無い。
    private func confirmPresence(onPhone: Bool) async -> AttendanceStampOutcome {
        guard !isStampCeremonyRunning else { return .failed }
        isStampCeremonyRunning = true
        defer { isStampCeremonyRunning = false }
        return await runCeremony(.suspect(onPhone: onPhone))
    }

    /// 走っている Touch ID の演出を畳む。ダイアログを閉じ、結末を出さずにカットインも引っ込める。
    private func cancelPresenceCheck() {
        ceremonyGeneration += 1
        attendance.cancelAuthentication()
        cutIn.dismiss()
    }

    /// Touch ID の演出をひと続きで進める。
    @discardableResult
    private func runCeremony(_ variant: AttendanceCeremonyVariant) async -> AttendanceStampOutcome {
        ceremonyGeneration += 1
        let generation = ceremonyGeneration

        attendance.refreshAvailability()
        let definition = pet.controller.currentPet
        // パスワードにフォールバックする環境では「指を合わせる」が成立しないので、
        // カットインは出さずにペットの動きとセリフだけにする。
        let useCutIn = attendance.isBiometricsAvailable && (definition?.hasCutInImages ?? false)

        let opening = AttendanceCeremonyScript.opening(variant)
        pet.controller.playOnce(opening.animation)
        pet.controller.say(opening.kind)
        if useCutIn, let definition, let image = opening.cutInImage {
            cutIn.present(image, of: definition, on: pet.controller.currentScreen)
            // スライドインを見せてから認証ダイアログを出す。
            try? await Task.sleep(for: .seconds(Self.cutInLeadInSeconds))
        }

        let outcome = variant == .stamp ? await attendance.stamp() : await attendance.verify()

        // 待っているあいだに畳まれていたら、結末の演出は出さない(カットインは畳んだ側が閉じている)。
        guard generation == ceremonyGeneration else { return outcome }

        let closing = AttendanceCeremonyScript.closing(outcome, variant: variant)
        pet.controller.playOnce(closing.animation)
        pet.controller.say(closing.kind)
        guard useCutIn, let image = closing.cutInImage else { return outcome }
        cutIn.swap(to: image, flash: outcome == .stamped)
        try? await Task.sleep(for: .seconds(Self.cutInHoldSeconds))
        cutIn.dismiss()
        return outcome
    }

    public func startBreak() {
        detection.startBreak()
    }

    public func endBreak() {
        detection.endBreak()
    }

    public func openDiscordSettings() {
        windows.showDiscord { DiscordView(discord: discord, daemon: daemon) }
    }

    public func openPermissions() {
        showPermissionWindow(canStart: !hasBegun)
    }

    public func toggleStatusPanel() {
        statusPanel.toggle { statusPanelView }
        isStatusPanelVisible = statusPanel.isVisible
    }

    public var voiceMode: VoiceMode { voiceModeStore.mode }

    public func setVoiceMode(_ mode: VoiceMode) {
        voiceModeStore.set(mode)
    }

    public var focusStreakIntervalSeconds: TimeInterval {
        detection.thresholds.focusStreakIntervalSeconds
    }

    public func setFocusStreakInterval(_ seconds: TimeInterval) {
        detection.thresholds = detection.thresholds.withFocusStreakInterval(seconds)
        objectWillChange.send()
    }

    public func replayFocusStreak() {
        pet.sayFocusStreak()
    }

    public func runDetectionStep(_ step: DetectionDebugStep) {
        detection.runDebugStep(step)
    }

    /// 説教オーバーレイを組み立てる。セリフの取得と読み上げの停止はこのアプリのものを渡す。
    private func makeOverlay() -> OverlayModel {
        let voice = self.voice
        let daemon = self.daemon
        let modes = self.voiceModeStore
        let player = self.speechPlayer
        return OverlayModel(
            presenter: ScreenSaverOverlayPresenter(),
            speak: { request in
                // 同封音声のときは bridge に作らせず、同封の説教から 1 本選んでその場で鳴らす。
                if modes.mode == .bundled {
                    guard let sermon = BundledVoiceLines.shared.pick(.sermon) else { return nil }
                    if let audio = sermon.audio { player.play(audio: audio, priority: .detection) }
                    return sermon.text
                }
                return await voice.speak(request, using: daemon.connectedClient)
            },
            stopSpeaking: { [weak voice] in voice?.stopSpeaking() }
        )
    }

    /// 状態パネルの中身。エンジンとデーモンの `@Published` をそのまま映す。
    private var statusPanelView: StatusPanelView {
        StatusPanelView(engine: detection, daemon: daemon)
    }

    // MARK: - 配線

    /// 検知エンジンの実行部に、実際の機能を配線する。
    ///
    /// どの実行部も「失敗したら諦めて次へ」に倒してある。カメラが使えない、
    /// VOICEVOX が起動していない、Discord のトークンが無い、はどれも起こりうる。
    /// 1 つ転んだせいで見張りが死ぬのが一番まずい。
    private func wireDetection() {
        let capture = CaptureService()
        detection.actions = DetectionEngine.Actions(
            captureMacPhoto: { await Self.photoData(from: capture) },
            captureIPhoneScreenshot: { [daemon] in
                try? await daemon.connectedClient?.iphoneScreenshot()
            },
            speak: { [voice, daemon] request in
                // 音声はここでは鳴らさない。吹き出しが出る瞬間に鳴らせるよう、ペットまで運ぶ。
                guard let line = await voice.fetchLine(request, using: daemon.connectedClient) else {
                    return nil
                }
                return SpokenSpeech(text: line.text, audio: line.audioData, screen: line.screen)
            },
            readScreen: { [daemon] request in
                guard let client = await daemon.connectedClient else { return nil }
                return try? await client.readScreen(request)
            },
            interrupt: { [overlay] request in
                await MainActor.run { overlay.show(request: request) }
            },
            post: { [discord, daemon] text, image, filename, mention in
                await discord.post(
                    text: text,
                    image: image,
                    filename: filename,
                    mention: mention,
                    using: daemon.connectedClient
                )
            },
            classify: { data in
                Self.visionLabel(for: data)
            },
            askHeadGesture: { [questioner] question, answerWindow in
                await questioner.ask(prompt: question, answerWindow: answerWindow)
            },
            confirmPresence: { [weak self] onPhone in
                guard let self else { return .unavailable }
                return await self.confirmPresence(onPhone: onPhone)
            },
            cancelPresenceCheck: { [weak self] in
                await MainActor.run { self?.cancelPresenceCheck() }
            }
        )
        detection.onEvent = { [pet] event in
            pet.present(event)
        }
        detection.onPromptDismissed = { [pet] in
            pet.dismissPrompt()
        }
        detection.onFocusStreak = { [pet] in
            pet.sayFocusStreak()
        }
    }

    /// 監視の状態をペットとメニューに映す。
    private func observeDetection() {
        detection.$isWatching
            .combineLatest(detection.$breakUntil)
            .sink { [weak self] isWatching, breakUntil in
                MainActor.assumeIsolated {
                    self?.applyMonitoring(isWatching: isWatching, breakUntil: breakUntil)
                }
            }
            .store(in: &cancellables)
    }

    private func applyMonitoring(isWatching: Bool, breakUntil: Date?) {
        let onBreak = breakUntil.map { Date() < $0 } ?? false
        self.isWatching = isWatching
        self.isOnBreak = onBreak

        if onBreak {
            pet.setMonitoring(.onBreak)
        } else if isWatching {
            pet.setMonitoring(.watching)
        } else {
            pet.setMonitoring(.paused)
        }
    }

    /// SSE で届いたイベントを検知エンジンに反映する。
    ///
    /// `@Published` の通知は値が入る**前**に来るので、`daemon.events` を読み直さず
    /// 流れてきた値をそのまま使う。
    private func observeDaemonEvents() {
        daemon.$events
            .compactMap(\.first)
            .removeDuplicates { $0.id == $1.id }
            .sink { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handle(event)
                }
            }
            .store(in: &cancellables)
    }

    private func handle(_ event: DaemonEvent) {
        switch event.name {
        case "iphone.state":
            applyIPhoneState(event)
        case "watch.start":
            // Discord の /watch から始めた場合。すでに見張っていれば何も起きない。
            detection.start()
        case "watch.stop":
            detection.stop()
        default:
            break
        }
    }

    private func applyIPhoneState(_ event: DaemonEvent) {
        guard let raw = event.payload["activity"] else { return }
        switch raw {
        case "active": detection.iphoneState = .active
        case "idle": detection.iphoneState = .idle
        // Python 側は状態取得を "unresponsive"、セリフ生成を "unreachable" と呼んでいる。
        // どちらも「iPhone から返事が無い」で、Swift では同じ 1 つの値に寄せる。
        default: detection.iphoneState = .unreachable
        }
        // 触っていないときの「前に開いていたアプリ」は古い情報でしかない。持ち越さない。
        guard raw == "active" else {
            detection.iphoneForegroundApp = nil
            return
        }
        detection.iphoneForegroundApp =
            Self.payloadText(event.payload["foreground_app_name"])
            ?? Self.payloadText(event.payload["foreground_bundle_id"])
    }

    /// payload の文字列から「中身のある値」だけを取り出す。
    ///
    /// `DaemonEvent` は payload を表示用の文字列に潰すので、JSON の null は `"null"` という
    /// 文字列で届く。空文字と併せて、無かったことにする。
    private static func payloadText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null" else { return nil }
        return trimmed
    }

    // Vision の解析は画面の都合と無関係なので、メインアクタから外して実行する。
    nonisolated private static func photoData(from capture: CaptureService) async -> Data? {
        guard let artifact = try? await capture.capturePhoto() else { return nil }
        let data = try? Data(contentsOf: artifact.url)
        // 送信のあとに残す理由がない。読み終えたらすぐ消す。
        try? artifact.delete()
        return data
    }

    nonisolated private static func visionLabel(for data: Data) -> SpeechRequest.VisionLabel {
        guard let image = try? CaptureImageCodec.decode(data) else { return .unknown }
        return VisionLabelClassifier.classify(outcome: FaceVisionAnalyzer.analyze(image))
    }
}
