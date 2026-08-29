import Foundation
import Testing

@testable import MihariCore

/// `PlaceholderPetPresenter` の状態更新だけを検証する。`show()` は NSWindow を作るため、
/// このテストからは一度も呼ばない。
@Suite("暫定ペット実装のイベント反映")
@MainActor
struct PlaceholderPetPresenterTests {

    @Test("イベントを渡すと state / visionLabel / 吹き出しに反映される")
    func presentUpdatesPublishedState() {
        let presenter = PlaceholderPetPresenter()
        let event = PetEvent(state: .confirmed, escalationStage: 2, line: "サボり確定", visionLabel: .absent)

        presenter.present(event)

        #expect(presenter.state == .confirmed)
        #expect(presenter.visionLabel == .absent)
        #expect(presenter.speechText == "サボり確定")
    }

    @Test("セリフが空のイベントは吹き出しを変えない")
    func presentWithEmptyLineKeepsSpeechText() {
        let presenter = PlaceholderPetPresenter()
        presenter.present(PetEvent(state: .normal, escalationStage: 0, line: "最初のセリフ"))
        presenter.present(PetEvent(state: .suspected, escalationStage: 1, line: ""))

        #expect(presenter.speechText == "最初のセリフ")
        #expect(presenter.state == .suspected)
    }

    @Test("吹き出し表示中に届いたセリフはキューに積まれる")
    func queuesLineWhileBubbleIsShowing() {
        let presenter = PlaceholderPetPresenter()
        presenter.present(PetEvent(state: .normal, escalationStage: 0, line: "1つ目"))
        presenter.present(PetEvent(state: .normal, escalationStage: 0, line: "2つ目"))

        #expect(presenter.speechText == "1つ目")
        #expect(presenter.speechQueue.count == 1)
    }

    @Test("問いかけ付きイベントは pendingPrompt に反映される")
    func presentWithPromptExposesPendingPrompt() {
        let presenter = PlaceholderPetPresenter()
        let prompt = PetYesNoPrompt(question: "作業中？") { _ in }
        presenter.present(PetEvent(state: .suspected, escalationStage: 1, line: "", prompt: prompt))

        #expect(presenter.pendingPrompt?.question == "作業中？")
    }

    @Test("answerPrompt を呼ぶと onAnswer に回答が伝わり、問いかけは消える")
    func answerPromptInvokesCallbackAndClearsPrompt() {
        let presenter = PlaceholderPetPresenter()
        let recorder = AnswerRecorder()
        let prompt = PetYesNoPrompt(question: "作業中？") { answer in recorder.record(answer) }
        presenter.present(PetEvent(state: .suspected, escalationStage: 1, line: "", prompt: prompt))

        presenter.answerPrompt(false)

        #expect(recorder.lastAnswer == false)
        #expect(presenter.pendingPrompt == nil)
    }

    @Test("画像設定を変えると imageSource が再判定される")
    func changingConfigurationReresolvesImageSource() {
        let presenter = PlaceholderPetPresenter()
        #expect(presenter.imageSource == .symbol(name: PetConfiguration.defaultPlaceholderSymbolName))

        presenter.configuration = PetConfiguration(imagePath: nil, placeholderSymbolName: "pawprint.fill")

        #expect(presenter.imageSource == .symbol(name: "pawprint.fill"))
    }
}
