import Testing

@testable import MihariCore

@Suite("吹き出しの大きさ")
@MainActor
struct PetSpeechBubbleViewTests {

    /// 短い質問。文字幅よりボタン列のほうが広くなる。
    private let shortQuestion = "休憩中?"
    /// 長い質問。文字幅だけでボタン列より広くなる。
    private let longQuestion = "まだ作業中ですか? 少し休みませんか? 水分はとりましたか?"

    @Test("短い質問はボタンを出すぶんだけ横に広がる")
    func shortQuestionWidensForButtons() {
        let withButtons = PetSpeechBubbleView.windowSize(for: shortQuestion, hasButtons: true)
        let withoutButtons = PetSpeechBubbleView.windowSize(for: shortQuestion, hasButtons: false)

        #expect(withButtons.width > withoutButtons.width)
        #expect(withButtons.width >= PetSpeechBubbleView.buttonsRowWidth)
    }

    @Test("長い質問ではボタンの有無で幅が変わらず、高さだけ増える")
    func longQuestionKeepsItsWidth() {
        let withButtons = PetSpeechBubbleView.windowSize(for: longQuestion, hasButtons: true)
        let withoutButtons = PetSpeechBubbleView.windowSize(for: longQuestion, hasButtons: false)

        #expect(withButtons.width == withoutButtons.width)
        #expect(
            withButtons.height
                == withoutButtons.height + PetSpeechBubbleView.buttonsSpacing
                + PetSpeechBubbleView.buttonsHeight
        )
    }
}
