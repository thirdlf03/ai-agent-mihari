import SwiftUI

/// ペットの表示設定と動作確認をする画面。
///
/// `RootView` には組み込んでいない（統合は別タスクで行う）。使う側は
/// `PlaceholderPetPresenter` のインスタンスをここと検知エンジンの両方に渡せばよい。
public struct PetView: View {
    @ObservedObject var presenter: PlaceholderPetPresenter
    @State private var imagePathText: String

    private static let sampleEvents: [PetEvent] = [
        PetEvent(state: .suspected, escalationStage: 1, line: "そろそろ戻ってきなよ〜", visionLabel: .lookingAway),
        PetEvent(state: .confirmed, escalationStage: 2, line: "サボり確定、証拠を送るよ", visionLabel: .absent),
    ]

    public init(presenter: PlaceholderPetPresenter) {
        self.presenter = presenter
        _imagePathText = State(initialValue: presenter.configuration.imagePath ?? "")
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                visibilityControls
                imagePathField
                testEventControls
                statusSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ペット").font(.title2).bold()
            Text("暫定は画像1枚のプレースホルダ。検知エンジンからのイベントは PetPresenting 経由で届く。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var visibilityControls: some View {
        HStack(spacing: 10) {
            Button(presenter.isVisible ? "隠す" : "表示する") {
                presenter.isVisible ? presenter.hide() : presenter.show()
            }
            Spacer()
        }
    }

    private var imagePathField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("画像ファイルのパス").font(.headline)
            Text("空、または存在しないパスなら SF Symbols のプレースホルダを描く。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("例: /Users/you/mihari-pet.png", text: $imagePathText)
                Button("反映") { applyImagePath() }
            }
        }
    }

    private var testEventControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("動作確認").font(.headline)
            HStack(spacing: 10) {
                ForEach(Array(Self.sampleEvents.enumerated()), id: \.offset) { index, event in
                    Button("サンプルイベント \(index + 1)") { presenter.present(event) }
                }
                Button("はい/いいえを聞く") { presenter.present(Self.samplePromptEvent()) }
                Spacer()
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("現在の状態").font(.headline)
            Text("state: \(presenter.state.label) / vision: \(presenter.visionLabel.label)")
                .font(.system(size: 12, design: .monospaced))
            if let speech = presenter.speechText {
                Text("吹き出し: \(speech)").font(.system(size: 12, design: .monospaced))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func applyImagePath() {
        presenter.configuration = PetConfiguration(
            imagePath: imagePathText.isEmpty ? nil : imagePathText,
            windowSize: presenter.configuration.windowSize,
            placeholderSymbolName: presenter.configuration.placeholderSymbolName
        )
    }

    private static func samplePromptEvent() -> PetEvent {
        PetEvent(
            state: .suspected,
            escalationStage: 1,
            line: "まだ作業中？",
            visionLabel: .none,
            prompt: PetYesNoPrompt(question: "作業中？") { _ in }
        )
    }
}
