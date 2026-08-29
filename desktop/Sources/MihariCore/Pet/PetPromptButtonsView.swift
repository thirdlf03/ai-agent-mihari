import SwiftUI

/// はい/いいえ の問いかけに、クリックでも答えられるようにするボタン列。
///
/// AirPods の首振り判定（#18）が使えない・未接続のときの手動フォールバックにもなる。
struct PetPromptButtonsView: View {
    let prompt: PetYesNoPrompt
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(prompt.question)
                .font(.callout)
                .foregroundStyle(.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 220)
            HStack(spacing: 8) {
                Button("はい") { onAnswer(true) }
                Button("いいえ") { onAnswer(false) }
            }
        }
    }
}
