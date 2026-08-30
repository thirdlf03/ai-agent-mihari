import SwiftUI

/// セリフ生成と読み上げの確認画面。
public struct VoiceView: View {
    @ObservedObject var voice: VoiceController
    @ObservedObject var daemon: DaemonController
    @ObservedObject var voiceMode: VoiceModeStore

    @State private var idleSeconds = 300
    @State private var escalation: SpeechRequest.Escalation = .nudge
    @State private var iphone: SpeechRequest.IPhoneState = .unreachable
    @State private var vision: SpeechRequest.VisionLabel = .unknown
    @State private var previewKind: BundledVoiceKind = .greeting
    /// 直近に試聴したセリフ。音声が無ければテキストだけが出る。
    @State private var previewedLine: BundledVoiceLine?

    public init(voice: VoiceController, daemon: DaemonController, voiceMode: VoiceModeStore) {
        self.voice = voice
        self.daemon = daemon
        self.voiceMode = voiceMode
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                modeSection
                bundledSection
                situation
                controls
                if let error = voice.lastError {
                    errorBox(error)
                }
                historySection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await voice.refreshStatus(using: daemon.connectedClient) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("セリフと声").font(.title2).bold()
            Text("同封の音声を鳴らすか、その場で VOICEVOX に合成させるかを選ぶ。どちらが欠けても、検知と送信は止まらない。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label("いまは「\(voiceMode.mode.label)」", systemImage: "waveform")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let status = voice.status {
                Label(status.summary, systemImage: statusIcon(status))
                    .font(.callout)
                    .foregroundStyle(statusColor(status))
                Text("モデル: \(status.llmModel) / VOICEVOX: \(status.voicevoxURL) (話者 \(status.voicevoxSpeaker))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(screenLLMLine(status))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            } else {
                Label("状態を取得できていない", systemImage: "questionmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// いまどちらの音声モードかと、その切り替え。
    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("音声モード").font(.headline)
            Picker("音声モード", selection: modeBinding) {
                ForEach(VoiceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(
                "同封は、あらかじめ作っておいた .m4a をそのまま鳴らす(VOICEVOX は要らない)。"
                    + "live は bridge にセリフを作らせて VOICEVOX で合成する。"
                    + "起動時に MIHARI_VOICE_MODE=live / bundled を付けると、そちらが優先される。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 選んだ区分から同封音声を 1 本鳴らして、その文面を出す。
    private var bundledSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("同封音声の試聴").font(.headline)
            HStack(spacing: 10) {
                Picker("区分", selection: $previewKind) {
                    ForEach(BundledVoiceKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .frame(width: 260)
                Button("再生") { previewedLine = voice.previewBundled(previewKind) }
                Spacer()
            }
            if let previewedLine {
                Text(previewedLine.text).font(.body).textSelection(.enabled)
                if previewedLine.audio == nil {
                    Text("音声ファイルが無い。scripts/generate_voice_lines.py で作り直す。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("まだ試聴していない。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    /// `VoiceModeStore` は自分で値を持つので、Picker には読み書きを繋ぎ直したものを渡す。
    private var modeBinding: Binding<VoiceMode> {
        Binding(get: { voiceMode.mode }, set: { voiceMode.set($0) })
    }

    private var situation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("渡す状況").font(.headline)
            HStack {
                Text("無操作")
                Stepper("\(idleSeconds) 秒", value: $idleSeconds, in: 0...3600, step: 30)
                    .frame(width: 200)
                Spacer()
            }
            Picker("当たりの強さ", selection: $escalation) {
                Text("軽め（声かけ）").tag(SpeechRequest.Escalation.nudge)
                Text("強め（説教）").tag(SpeechRequest.Escalation.warn)
                Text("最大（晒す）").tag(SpeechRequest.Escalation.expose)
            }
            .pickerStyle(.segmented)
            Picker("iPhone", selection: $iphone) {
                Text("触っている").tag(SpeechRequest.IPhoneState.active)
                Text("置かれたまま").tag(SpeechRequest.IPhoneState.idle)
                Text("応答なし").tag(SpeechRequest.IPhoneState.unreachable)
            }
            .pickerStyle(.segmented)
            Picker("見立て", selection: $vision) {
                Text("不明").tag(SpeechRequest.VisionLabel.unknown)
                Text("寝てる").tag(SpeechRequest.VisionLabel.sleeping)
                Text("よそ見").tag(SpeechRequest.VisionLabel.lookingAway)
                Text("不在").tag(SpeechRequest.VisionLabel.absent)
            }
            .pickerStyle(.segmented)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button("喋らせる") {
                Task { await voice.speak(request, using: daemon.connectedClient) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!daemon.isRunning)

            Button("止める") { voice.stopSpeaking() }
                .disabled(!voice.isSpeaking)

            Button("状態を取り直す") {
                Task { await voice.refreshStatus(using: daemon.connectedClient) }
            }
            Spacer()
        }
    }

    private var request: SpeechRequest {
        SpeechRequest(
            idleSeconds: idleSeconds,
            escalation: escalation,
            frontmostApp: nil,
            iphone: iphone,
            vision: vision
        )
    }

    private func errorBox(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.orange)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("喋った内容").font(.headline)
            if voice.history.isEmpty {
                Text("まだ喋っていない。").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(voice.history) { utterance in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(utterance.at.formatted(date: .omitted, time: .standard))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(utterance.fromLLM ? "LLM" : "固定文言")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                            Image(systemName: utterance.spokenAloud ? "speaker.wave.2.fill" : "speaker.slash")
                                .font(.caption2)
                                .foregroundStyle(utterance.spokenAloud ? Color.green : Color.secondary)
                            Spacer()
                        }
                        Text(utterance.text).font(.body).textSelection(.enabled)
                        if let note = utterance.note {
                            Text(note).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 画面読み取り LLM の 1 行。古いデーモンだとモデル名が空で返るので、そのときは伏せる。
    private func screenLLMLine(_ status: VoiceStatus) -> String {
        let model = status.screenLLMModel.isEmpty ? "-" : status.screenLLMModel
        return "画面読み取り LLM: \(model)(\(status.screenLLMConfigured ? "設定済み" : "未設定"))"
    }

    private func statusIcon(_ status: VoiceStatus) -> String {
        status.llmConfigured && status.voicevoxReachable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func statusColor(_ status: VoiceStatus) -> Color {
        status.llmConfigured && status.voicevoxReachable ? .green : .orange
    }
}
