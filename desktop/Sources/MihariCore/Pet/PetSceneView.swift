import SwiftUI

/// ペットのウィンドウ内に表示する中身。吹き出し・問いかけ・画像を縦に重ねる。
struct PetSceneView: View {
    @ObservedObject var presenter: PlaceholderPetPresenter

    var body: some View {
        VStack(spacing: 8) {
            if let text = presenter.speechText {
                PetSpeechBubbleView(text: text)
            }
            if let prompt = presenter.pendingPrompt {
                PetPromptButtonsView(prompt: prompt) { answer in
                    presenter.answerPrompt(answer)
                }
            }
            petImage
        }
        .padding(4)
    }

    @ViewBuilder
    private var petImage: some View {
        switch presenter.imageSource {
        case .file(let path):
            if let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
            } else {
                // 設定パスはあったがその後消えた等、読み込みに失敗したときの保険。
                placeholder(symbolName: PetConfiguration.defaultPlaceholderSymbolName)
            }
        case .symbol(let name):
            placeholder(symbolName: name)
        }
    }

    private func placeholder(symbolName: String) -> some View {
        Image(systemName: symbolName)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.primary)
            .padding(20)
    }
}
