import SwiftUI

/// セリフを表示する吹き出し。表示時間の決定は `PetBubbleDurationPolicy` が担う。
struct PetSpeechBubbleView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 220)
    }
}
