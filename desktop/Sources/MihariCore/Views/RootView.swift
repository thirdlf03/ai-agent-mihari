import SwiftUI

/// アプリのルート。
///
/// ここが唯一「全機能を知っている」場所。各機能は互いを知らずに作ってあり、
/// 検知エンジンの実行部にそれぞれを差し込むことで初めて 1 つのアプリになる。
public struct RootView: View {
    @StateObject private var permissions = PermissionsModel()
    @StateObject private var daemon = DaemonController()
    @StateObject private var voice = VoiceController()
    @StateObject private var discord = DiscordController()
    @StateObject private var attendance = AttendanceModel()
    @StateObject private var detection = DetectionEngine()
    @StateObject private var overlay = OverlayModel(presenter: ScreenSaverOverlayPresenter())
    @StateObject private var pet = LivePetPresenter()
    @StateObject private var headGesture = HeadGestureController()
    @StateObject private var captureModel = CaptureViewModel()
    @StateObject private var visionModel = FaceVisionViewModel()

    public init() {}

    public var body: some View {
        TabView {
            DetectionView(engine: detection)
                .tabItem { Label("検知", systemImage: "eye") }
            DiscordView(discord: discord, daemon: daemon)
                .tabItem { Label("Discord", systemImage: "paperplane") }
            VoiceView(voice: voice, daemon: daemon)
                .tabItem { Label("セリフと声", systemImage: "waveform") }
            AttendanceView(model: attendance)
                .tabItem { Label("在席", systemImage: "touchid") }
            HeadGestureView(controller: headGesture)
                .tabItem { Label("首振り", systemImage: "airpodspro") }
            CaptureView(model: captureModel)
                .tabItem { Label("撮影", systemImage: "camera") }
            VisionView(model: visionModel)
                .tabItem { Label("見立て", systemImage: "face.dashed") }
            OverlayView()
                .tabItem { Label("説教", systemImage: "rectangle.inset.filled") }
            OnboardingView(model: permissions)
                .tabItem { Label("権限", systemImage: "lock.shield") }
            DaemonView(controller: daemon)
                .tabItem { Label("デーモン", systemImage: "gearshape.2") }
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            // デーモンを立ち上げてから、検知エンジンに各機能を差し込む。
            await daemon.start()
            wireDetection()
            // 常駐して見張るアプリなので、起動したら見張り始める。
            // ボタンを押すまで何も起きないのでは、そもそも監視にならない。
            detection.start()
        }
        .onChange(of: daemon.events.first?.id) { handleLatestEvent() }
        .onDisappear {
            detection.stop()
            pet.hide()
            daemon.stop()
        }
    }

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
            }
        )
        // ペットを出す。検知が発火したらここにセリフと状態が流れる。
        pet.show()
        detection.onEvent = { [pet] event in
            pet.present(event)
        }
    }

    /// SSE で届いたイベントを検知エンジンに反映する。
    private func handleLatestEvent() {
        guard let event = daemon.events.first else { return }
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

    // Vision の解析は View の都合と無関係なので、メインアクタから外して実行する。
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
