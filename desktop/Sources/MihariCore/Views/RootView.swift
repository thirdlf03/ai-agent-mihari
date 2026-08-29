import SwiftUI

/// 機能ごとの検証画面をタブで並べただけの画面。
///
/// ふだんの起動では出さず、`MIHARI_DEBUG_UI=1` のときだけ開く。配線は `AppCoordinator`
/// が済ませているので、ここは持っているコントローラを各タブに渡すだけにする。
public struct RootView: View {
    @ObservedObject private var coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        TabView {
            DetectionView(engine: coordinator.detection)
                .tabItem { Label("検知", systemImage: "eye") }
            DiscordView(discord: coordinator.discord, daemon: coordinator.daemon)
                .tabItem { Label("Discord", systemImage: "paperplane") }
            VoiceView(voice: coordinator.voice, daemon: coordinator.daemon)
                .tabItem { Label("セリフと声", systemImage: "waveform") }
            AttendanceView(model: coordinator.attendance)
                .tabItem { Label("在席", systemImage: "touchid") }
            HeadGestureView(controller: coordinator.headGesture)
                .tabItem { Label("首振り", systemImage: "airpodspro") }
            CaptureView(model: coordinator.capture)
                .tabItem { Label("撮影", systemImage: "camera") }
            VisionView(model: coordinator.vision)
                .tabItem { Label("見立て", systemImage: "face.dashed") }
            // OverlayView は単体で動くようデーモンを自前で立てる。検証用なのでそのまま使う。
            OverlayView()
                .tabItem { Label("説教", systemImage: "rectangle.inset.filled") }
            OnboardingView(model: coordinator.permissions)
                .tabItem { Label("権限", systemImage: "lock.shield") }
            DaemonView(controller: coordinator.daemon)
                .tabItem { Label("デーモン", systemImage: "gearshape.2") }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
