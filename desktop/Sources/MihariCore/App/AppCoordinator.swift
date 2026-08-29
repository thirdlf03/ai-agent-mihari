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
    public let discord = DiscordController()
    public let attendance: AttendanceModel
    public let detection: DetectionEngine
    public let overlay = OverlayModel(presenter: ScreenSaverOverlayPresenter())
    public let pet: LivePetPresenter
    public let questioner = HeadGestureQuestioner()

    // 以下は検証用の 10 タブ画面でしか使わないので、開かれるまで作らない。
    public lazy var capture = CaptureViewModel()
    public lazy var vision = FaceVisionViewModel()
    public lazy var headGesture = HeadGestureController()

    /// 監視中か。メニューの表示に使う。
    @Published public private(set) var isWatching = false
    /// 休憩中か。メニューの表示に使う。
    @Published public private(set) var isOnBreak = false
    /// 状態パネルを出しているか。メニューの表示に使う。
    @Published public private(set) var isStatusPanelVisible = false

    /// 音を出す口。検知のセリフとペットのひとりごとで 1 つを共有する。
    private let speechPlayer: SpeechPlayer
    /// アプリの外(Claude Code のフックなど)からの合図の受け口。
    private let externalTrigger = ExternalTriggerListener()
    private let windows = AuxiliaryWindows()
    private let statusPanel = StatusPanelController()
    private var cancellables: Set<AnyCancellable> = []
    /// すでに見張り始めたか。`begin()` を何度呼んでも 1 回しか効かないようにする。
    private var hasBegun = false

    public init() {
        let player = SpeechPlayer()
        let attendance = AttendanceModel()
        self.speechPlayer = player
        self.attendance = attendance
        self.permissions = PermissionsModel()
        self.voice = VoiceController(player: player)
        // 在席スタンプ直後の猶予を効かせるため、検知エンジンに在席の記録を渡す。
        self.detection = DetectionEngine(attendance: attendance)
        self.pet = LivePetPresenter(controller: PetController(speechPlayer: player))
        self.isStatusPanelVisible = statusPanel.isVisible
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

        // 右クリックメニューはウィンドウを作る前に差し込む。
        pet.controller.contextMenuBuilder = { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(PetMenuContent(actions: self, pet: pet.controller))
        }
        pet.show()
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
        }
    }

    /// 終了時の後片付け。見張りを止めて、子プロセスのデーモンも落とす。
    public func shutdown() {
        detection.stop()
        daemon.stop()
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

    public func stampAttendance() {
        Task { [weak self] in
            guard let self else { return }
            let before = attendance.stamps.count
            await attendance.stamp()
            let stamped = attendance.stamps.count > before
            // 音声は検知のセリフと取り合いになるので、吹き出しだけ出す。
            pet.controller.say(stamped ? "在席、確認したよ" : "確認できなかった…", voiced: false)
        }
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
                await voice.speak(request, using: daemon.connectedClient)
            },
            interrupt: { [overlay] request in
                await MainActor.run { overlay.show(request: request) }
            },
            post: { [discord, daemon] text, image, filename in
                await discord.post(text: text, image: image, filename: filename, using: daemon.connectedClient)
            },
            classify: { data in
                Self.visionLabel(for: data)
            },
            askHeadGesture: { [questioner] question, answerWindow in
                await questioner.ask(prompt: question, answerWindow: answerWindow)
            }
        )
        detection.onEvent = { [pet] event in
            pet.present(event)
        }
        detection.onPromptDismissed = { [pet] in
            pet.dismissPrompt()
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
