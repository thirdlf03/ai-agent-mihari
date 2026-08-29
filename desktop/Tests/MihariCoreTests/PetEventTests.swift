import Foundation
import Testing

@testable import MihariCore

@Suite("ペットへ渡すイベントの組み立て")
struct PetEventTests {

    @Test("通常のイベントはそのまま各値を保持する")
    func buildsEventAsGiven() {
        let event = PetEvent(state: .suspected, escalationStage: 2, line: "戻ってきなよ", visionLabel: .lookingAway)
        #expect(event.state == .suspected)
        #expect(event.escalationStage == 2)
        #expect(event.line == "戻ってきなよ")
        #expect(event.visionLabel == .lookingAway)
        #expect(event.prompt == nil)
    }

    @Test("エスカレーション段階に負の値を渡すと 0 に丸める")
    func clampsNegativeEscalationStage() {
        let event = PetEvent(state: .normal, escalationStage: -3, line: "")
        #expect(event.escalationStage == PetEvent.minimumEscalationStage)
    }

    @Test("visionLabel と prompt は省略できる")
    func fillsDefaultsWhenOmitted() {
        let event = PetEvent(state: .normal, escalationStage: 0, line: "こんにちは")
        #expect(event.visionLabel == .none)
        #expect(event.prompt == nil)
    }

    @Test("prompt を渡すと onAnswer に回答が伝わる")
    func promptDeliversAnswerThroughCallback() {
        let recorder = AnswerRecorder()
        let prompt = PetYesNoPrompt(question: "作業中？") { answer in
            recorder.record(answer)
        }
        let event = PetEvent(state: .suspected, escalationStage: 1, line: "まだいる？", prompt: prompt)

        event.prompt?.onAnswer(true)

        #expect(recorder.answers == [true])
        #expect(event.prompt?.question == "作業中？")
    }
}
