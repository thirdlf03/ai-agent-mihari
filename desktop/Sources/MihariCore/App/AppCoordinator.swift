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
    /// スクショに写り込むかを覚えておくキー。未設定なら写り込む。
    static let photobombEnabledKey = "photobombEnabled"

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
    /// 作業部屋の仕事の進捗。ペットの右クリック / メニューバーから操作する。
    public let room: RoomJobMonitor
    /// 依頼単位でこの Mac を撮影・操作する口（#23）。既定はオフで、許可は依頼ごと。
    public let macControl = MacControlCenter()
    /// §5-2: room voice Realtime 会話（録音・VOICEVOX・割り込み・履歴）。
    public lazy var voiceConversation: VoiceConversationController = makeVoiceConversation()
    /// 操作中の常設表示（停止ボタン付き）。macControl に差し込む。
    private let macControlIndicator = MacControlOperationPanelIndicator()
    /// いま固定して操作対象にしている仕事。一覧・詳細で選んだ仕事が入る。
    @Published public private(set) var pinnedRoomJobID: String?
    /// 部屋が対応している機能。旧バックエンドでは未対応操作を出さないための判断に使う。
    @Published public private(set) var roomCapabilities: RoomCapabilities?

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
    /// スクショに写り込むか。メニューの表示に使う。
    @Published public private(set) var isPhotobombEnabled: Bool

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
    /// スクリーンショットが保存されたのを見張る。
    private let photobombWatcher = ScreenshotPhotobombWatcher()
    /// 保存されたスクショにペットのスプライトを描き足す層。
    ///
    /// セリフをペットの吹き出しに繋ぐため、`self` を参照できる `lazy var` にしてある。
    private lazy var photobomb = ScreenshotPhotobombCompositor(
        say: { [weak self] line in
            self?.pet.controller.say(line)
        }
    )
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
        // 部屋の購読は自分専用のセッションで開く。デーモン(bridge)の SSE とは別なので奪わない。
        self.room = RoomJobMonitor(
            access: RoomEventClient.makeFromEnvironment(),
            cursorStore: UserDefaultsRoomJobCursorStore(defaults: .standard)
        )
        self.isStatusPanelVisible = statusPanel.isVisible
        // 一度も切っていなければ写り込む。余興なので、既定で入っている方が気付いてもらえる。
        self.isPhotobombEnabled =
            UserDefaults.standard.object(forKey: Self.photobombEnabledKey) as? Bool ?? true
        self.sleepPreventer = sleepPreventer
        self.loginItemRegistrar = loginItemRegistrar
        self.watchdogRegistrar = watchdogRegistrar
        self.lifecycleMarker = lifecycleMarker
        // 操作中の表示と停止ボタンを結ぶ。
        macControl.operationIndicator = macControlIndicator
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

        // 部屋の対応機能を引き、旧バックエンドなら未対応操作（仕事一覧など）を出さない。
        Task { [weak self] in
            let caps = await JobRequestClient.makeFromEnvironment().fetchCapabilities()
            self?.roomCapabilities = caps
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
        // 部屋の位相変化をペットへ写す。検知のセリフと同じ口(共有の SpeechPlayer)を通すので、
        // 二重に鳴らない。
        room.onDirective = { [weak self] tracked in
            guard let self else { return }
            if let directive = tracked.directive {
                self.applyRoomDirective(directive)
            }
        }

        // Claude Code の Stop フック(notifyutil -p)からの「応答を終えた」合図。
        externalTrigger.listen(name: ExternalTriggerListener.claudeDoneName) { [weak self] in
            Task { @MainActor [weak self] in
                self?.pet.controller.say("終わったよー")
            }
        }

        // 保存されたスクショに、あとからペットのスプライトを描き足して写り込む。
        if isPhotobombEnabled {
            startPhotobombWatching()
        }

        Task { [weak self] in
            guard let self else { return }
            await daemon.start()
            wireDetection()
            // 常駐して見張るアプリなので、始めたら見張り続ける。
            detection.start()
            // 起動時に走っている仕事を拾って監視する(依頼窓から頼んだ仕事はその場で監視する)。
            await room.resume()
            // 依頼から Mac を操作してもらうための接続。認証済みでない限り何も送られない。
            macControl.start()

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
        photobombWatcher.stop()
        daemon.stop()
        room.stopAll()
        // 部屋へ「アプリが終了する」を伝えてから接続を閉じる（失効は hub 側）。
        if voiceConversation.isActive {
            voiceConversation.stop()
        }
        macControl.sendQuit()
        Task { [weak self] in
            // 1 フレーム届く猶予を置いてから閉じる。届かなくても TCP 切断で失効する。
            try? await Task.sleep(for: .milliseconds(300))
            self?.macControl.stop()
        }
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

    /// 作業部屋への仕事の依頼窓を開く。行き先とトークンは環境変数で決まる。
    ///
    /// 依頼が通ったら、その仕事の進捗を監視し始め、操作対象として固定する。
    public func openJobRequest() {
        JobRequestWindowController.shared.show(
            client: JobRequestClient.makeFromEnvironment(),
            onSubmitted: { [weak self] jobID, title in
                Task { @MainActor in
                    self?.room.attach(jobID: jobID, title: title)
                    self?.pinRoomJob(jobID)
                    // 成功したら下書きを消して、当該ジョブの詳細を開く（成果確認からの導線）。
                    self?.openRoomJobDetail(jobID: jobID)
                }
            }
        )
    }

    /// 仕事一覧の窓を開く。選んだ仕事の詳細を固定して開く。
    public func openRoomJobList() {
        RoomJobListWindowController.shared.show(
            access: RoomEventClient.makeFromEnvironment(),
            monitor: room,
            onOpenJob: { [weak self] jobID in
                self?.openRoomJobDetail(jobID: jobID)
            },
            onOpenRequest: { [weak self] in
                self?.openJobRequest()
            }
        )
    }

    /// 操作対象の仕事を固定する。別ジョブの進捗で追記・中断・承認の行き先が変わらないようにする。
    public func pinRoomJob(_ jobID: String) {
        pinnedRoomJobID = jobID
    }

    // MARK: - 作業部屋の操作

    /// いま操作対象にしている仕事(固定があればそれ)。無ければ `nil`。
    private var currentRoomJobID: String? {
        if let pinned = pinnedRoomJobID, room.isTracking(pinned) {
            return pinned
        }
        return room.jobs.first?.jobID
    }

    /// いま追っている仕事(直近に動いたもの)。無ければ `nil`。
    public var roomJob: RoomJobSummary? {
        if let pinned = pinnedRoomJobID,
            let job = room.jobs.first(where: { $0.jobID == pinned })
        {
            return job.summary
        }
        return room.jobs.first?.summary
    }

    /// 走っている仕事へ追記する窓を開く。
    public func followUpRoomJob() {
        guard let jobID = currentRoomJobID else { return }
        JobRequestWindowController.shared.showFollowup(
            client: RoomEventClient.makeFromEnvironment(),
            jobID: jobID
        )
    }

    /// 仕事の詳細パネルを開く。記憶の候補はここで本文と承認・却下を見せる。
    public func openRoomJobDetail() {
        guard let jobID = currentRoomJobID else { return }
        openRoomJobDetail(jobID: jobID)
    }

    /// 指定した仕事の詳細を開く。監視していなければ詳細から拾い直してから見せる。
    public func openRoomJobDetail(jobID: String) {
        pinRoomJob(jobID)
        showRoomJobDetail(jobID: jobID)
        Task { @MainActor in
            if !room.isTracking(jobID) {
                let client = RoomEventClient.makeFromEnvironment()
                if let detail = try? await client.detail(jobID: jobID) {
                    room.attach(detail: detail)
                }
            }
            await room.refreshMemory(jobID: jobID)
        }
    }

    private func showRoomJobDetail(jobID: String) {
        let title = room.jobs.first(where: { $0.jobID == jobID })?.title ?? "仕事の詳細"
        RoomJobDetailWindowController.shared.show(
            monitor: room,
            jobID: jobID,
            onOpenArtifact: { [weak self] url in self?.openRoomArtifact(url) },
            onPreviewAuthenticated: { [weak self] previewJobID, version in
                self?.openRoomArtifactPreview(jobID: previewJobID, version: version, title: title)
            }
        )
    }

    /// 非公開版の認証付きアプリ内プレビューを開く。トークンはヘッダだけに載せる。
    public func openRoomArtifactPreview(jobID: String, version: String, title: String) {
        RoomArtifactPreviewWindowController.shared.show(
            client: RoomEventClient.makeFromEnvironment(),
            jobID: jobID,
            version: version,
            title: "プレビュー v\(version) - \(title)"
        )
    }

    /// 走っている仕事を中断する。
    public func cancelRoomJob() {
        guard let jobID = currentRoomJobID else { return }
        Task {
            _ = try? await room.cancel(jobID: jobID)
        }
    }

    /// 成果物の URL を開く。http / https だけを開き、それ以外は無視する。
    public func openRoomArtifact(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// 作業部屋メニューから記憶の候補を承認する。
    public func approveRoomMemory(candidateID: String) {
        guard let jobID = currentRoomJobID else { return }
        Task {
            try? await room.approveMemory(jobID: jobID, candidateID: candidateID)
        }
    }

    /// 作業部屋メニューから記憶の候補を却下する。
    public func rejectRoomMemory(candidateID: String) {
        guard let jobID = currentRoomJobID else { return }
        Task {
            try? await room.rejectMemory(jobID: jobID, candidateID: candidateID)
        }
    }

    /// 作業部屋メニューから静的プレビューを指定バージョンへ戻す。
    public func rollbackRoomArtifact(version: String) {
        guard let jobID = currentRoomJobID else { return }
        Task {
            _ = try? await room.rollbackArtifact(jobID: jobID, version: version)
        }
    }

    /// 部屋が仕事一覧を出せるか。`/capabilities` がとれるまではとりあえず出す。
    public var supportsRoomJobList: Bool {
        roomCapabilities?.supportsJobList ?? true
    }

    /// 部屋の位相変化をペットに反映する。検知と同じく、固定・一度きり・吹き出しの順で降ろす。
    private func applyRoomDirective(_ directive: RoomPhaseDirective) {
        pet.controller.setFixedAnimation(directive.fixedAnimation)
        if let once = directive.playOnce {
            pet.controller.playOnce(once)
        }
        if let line = directive.line {
            pet.controller.say(line)
        }
    }

    public func openPermissions() {
        showPermissionWindow(canStart: !hasBegun)
    }

    public func toggleStatusPanel() {
        statusPanel.toggle { statusPanelView }
        isStatusPanelVisible = statusPanel.isVisible
    }

    /// スクショへの写り込みを入れる / 切る。切り替えた結果は次の起動にも引き継ぐ。
    ///
    /// 見張り始める前に入れられても、見張りを始めるときに `begin()` が起こす。
    public func setPhotobombEnabled(_ enabled: Bool) {
        isPhotobombEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.photobombEnabledKey)
        if enabled {
            guard hasBegun else { return }
            startPhotobombWatching()
        } else {
            photobombWatcher.stop()
        }
    }

    /// 保存されたスクショを見張り始める。すでに見張っていれば何も起きない。
    private func startPhotobombWatching() {
        photobombWatcher.start { [weak self] url in
            Task { @MainActor [weak self] in
                await self?.photobomb.photobomb(url)
            }
        }
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

    public var isFastThresholds: Bool {
        detection.thresholds == .fast
    }

    /// 検知の閾値を preset ごと差し替える。
    /// 「集中継続の間隔」で個別に変えていた値も preset の値に戻る。
    public func setFastThresholds(_ enabled: Bool) {
        detection.thresholds = enabled ? .fast : .standard
        objectWillChange.send()
    }

    public func replayFocusStreak() {
        pet.sayFocusStreak()
    }

    public var isVoiceConversationActive: Bool {
        voiceConversation.isActive
    }

    public func startVoiceConversation() {
        voiceConversation.start()
        VoiceCallWindowController.shared.show(controller: voiceConversation)
        objectWillChange.send()
    }

    public func endVoiceConversation() {
        voiceConversation.stop()
        VoiceCallWindowController.shared.closeWindow()
        objectWillChange.send()
    }

    public func runVoicevoxRoundTripSmokeTest() {
        Task {
            await VoiceConversationSmoke.runRoundTrip(player: speechPlayer)
        }
    }

    /// §5-2 会話コントローラを組み立て、`SpeechPlayer` の完了通知を既存とチェーンする。
    private func makeVoiceConversation() -> VoiceConversationController {
        let controller = VoiceConversationController(
            deps: .makeDefault(speechPlayer: speechPlayer) { [weak self] jobID, title in
                self?.room.attach(jobID: jobID, title: title)
            }
        )
        let previousHandler = speechPlayer.onPlaybackFinished
        speechPlayer.onPlaybackFinished = { [weak controller] priority in
            previousHandler?(priority)
            Task { @MainActor in
                controller?.handlePlaybackFinished(priority: priority)
            }
        }
        return controller
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
