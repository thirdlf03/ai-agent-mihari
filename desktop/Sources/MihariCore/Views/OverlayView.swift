import SwiftUI

/// 音楽停止 + 全画面オーバーレイの確認画面。
///
/// 単体で使えるように、デーモンとセリフ読み上げ(`VoiceController`)は自前で持つ。
/// 呼び出し側(親)は `OverlayView()` を置くだけでよい。
public struct OverlayView: View {
    @StateObject private var daemon: DaemonController
    @StateObject private var voice: VoiceController
    @StateObject private var overlay: OverlayModel

    public init() {
        let daemon = DaemonController()
        let voice = VoiceController()
        _daemon = StateObject(wrappedValue: daemon)
        _voice = StateObject(wrappedValue: voice)
        _overlay = StateObject(
            wrappedValue: OverlayModel(
                presenter: ScreenSaverOverlayPresenter(),
                speak: { [weak voice, weak daemon] request in
                    await voice?.speak(request, using: daemon?.connectedClient)
                },
                stopSpeaking: { [weak voice] in voice?.stopSpeaking() }
            )
        )
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                settings
                controls
                statusSection
                logSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await daemon.start() }
        .onDisappear { daemon.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("説教オーバーレイ").font(.title2).bold()
            Text("サボりが確定したときに、音楽を止めて全画面オーバーレイを出し、説教を最後まで聞かせる。読み上げ完了か上限秒数のどちらかで必ず自動解除する。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("設定").font(.headline)
            HStack {
                Text("上限秒数")
                Stepper(
                    "\(overlay.maxDurationSeconds) 秒",
                    value: $overlay.maxDurationSeconds,
                    in: OverlayModel.durationRange,
                    step: 10
                )
                .frame(width: 200)
                .disabled(overlay.isPresented)
                Spacer()
            }
            Toggle("解除後に音楽を再開する", isOn: $overlay.resumeMusicAfterDismiss)
                .disabled(overlay.isPresented)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button("試す") { overlay.show() }
                .buttonStyle(.borderedProminent)
                .disabled(overlay.isPresented)
            Button("いますぐ解除") { overlay.dismissManually() }
                .disabled(!overlay.isPresented)
            Spacer()
        }
    }

    private var statusSection: some View {
        GroupBox("状態") {
            VStack(alignment: .leading, spacing: 4) {
                StatusLine(key: "表示中", value: overlay.isPresented ? "はい" : "いいえ")
                StatusLine(key: "直近の解除理由", value: overlay.lastDismissReason?.label ?? "-")
                StatusLine(key: "直近の音楽停止結果", value: overlay.lastMusicOutcome?.summary ?? "-")
                StatusLine(key: "デーモン", value: daemon.state.label)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("直近の実行ログ").font(.headline)
            if overlay.log.isEmpty {
                Text("まだ実行していない。").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(overlay.log) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.at.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .font(.system(size: 12))
                        Spacer()
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// `key: value` の 1 行。他の画面(`DaemonView` など)と同じ簡易表示。
private struct StatusLine: View {
    let key: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text("\(key):").foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
        .font(.system(size: 12, design: .monospaced))
    }
}
