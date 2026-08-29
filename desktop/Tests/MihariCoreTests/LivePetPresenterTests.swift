import Foundation
import Testing

@testable import MihariCore

/// 検知イベントをペットの動きへ変換するところだけを検証する。
/// `show()` を呼ばなければウィンドウは作られないので、`present` の結果は `lastDirective` で確かめる。
@Suite("検知イベントからペットの動きへの変換")
@MainActor
struct LivePetPresenterTests {

    /// 実行のたびに空の UserDefaults を使い、テスト同士が表示設定を共有しないようにする。
    private func makePresenter() -> LivePetPresenter {
        let suiteName = "mihari.test.pet.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return LivePetPresenter(controller: PetController(defaults: defaults))
    }

    @Test("疑いは waiting に固定し、セリフを吹き出しに出す")
    func suspectedFixesWaiting() {
        let presenter = makePresenter()

        presenter.present(PetEvent(state: .suspected, escalationStage: 0, line: "まだ作業中？"))

        #expect(presenter.lastDirective.fixedAnimation == .waiting)
        #expect(presenter.lastDirective.line == "まだ作業中？")
        #expect(presenter.lastDirective.playOnce == nil)
    }

    @Test("サボり確定は failed に固定する")
    func confirmedFixesFailed() {
        let presenter = makePresenter()

        presenter.present(PetEvent(state: .confirmed, escalationStage: 0, line: "サボり確定"))

        #expect(presenter.lastDirective.fixedAnimation == .failed)
        #expect(presenter.lastDirective.line == "サボり確定")
    }

    @Test("エスカレーション段階が上がったときだけ跳ねる")
    func jumpsOnlyWhenEscalationStageRises() {
        let presenter = makePresenter()

        presenter.present(PetEvent(state: .confirmed, escalationStage: 3, line: "三段階目"))
        #expect(presenter.lastDirective.playOnce == .jumping)

        presenter.present(PetEvent(state: .confirmed, escalationStage: 2, line: "二段階目"))
        #expect(presenter.lastDirective.playOnce == nil)

        presenter.present(PetEvent(state: .confirmed, escalationStage: 3, line: "三段階目"))
        #expect(presenter.lastDirective.playOnce == nil)

        presenter.present(PetEvent(state: .confirmed, escalationStage: 4, line: "四段階目"))
        #expect(presenter.lastDirective.playOnce == .jumping)
    }

    @Test("正常に戻ると固定を解いて一度だけ手を振る")
    func wavesWhenBackToNormal() {
        let presenter = makePresenter()
        presenter.present(PetEvent(state: .suspected, escalationStage: 0, line: "まだ作業中？"))

        presenter.present(PetEvent(state: .normal, escalationStage: 0, line: ""))

        #expect(presenter.lastDirective.fixedAnimation == nil)
        #expect(presenter.lastDirective.playOnce == .waving)
        #expect(presenter.lastDirective.line == nil)
    }

    @Test("正常が続くあいだは手を振らない")
    func doesNotWaveWhileStayingNormal() {
        let presenter = makePresenter()

        presenter.present(PetEvent(state: .normal, escalationStage: 0, line: ""))

        #expect(presenter.lastDirective.playOnce == nil)
    }

    @Test("正常に戻ったあとは段階が同じでも跳ね直す")
    func resetsEscalationStageAfterNormal() {
        let presenter = makePresenter()
        presenter.present(PetEvent(state: .confirmed, escalationStage: 2, line: "二段階目"))
        presenter.present(PetEvent(state: .normal, escalationStage: 0, line: ""))

        presenter.present(PetEvent(state: .confirmed, escalationStage: 2, line: "二段階目"))

        #expect(presenter.lastDirective.playOnce == .jumping)
    }

    @Test("問いかけの無いイベントが来ても問いかけは消えない")
    func keepsPromptWhenLaterEventHasNone() {
        let presenter = makePresenter()
        let recorder = AnswerRecorder()
        let prompt = PetYesNoPrompt(question: "作業中？") { recorder.record($0) }
        presenter.present(PetEvent(state: .suspected, escalationStage: 0, line: "", prompt: prompt))
        #expect(presenter.pendingPrompt != nil)

        presenter.present(PetEvent(state: .suspected, escalationStage: 0, line: "まだいる？"))

        #expect(presenter.pendingPrompt != nil)
        #expect(presenter.lastDirective.fixedAnimation == .waiting)
    }

    @Test("dismissPrompt で問いかけを捨てる。回答は呼ばない")
    func dismissPromptDropsPrompt() {
        let presenter = makePresenter()
        let recorder = AnswerRecorder()
        let prompt = PetYesNoPrompt(question: "作業中？") { recorder.record($0) }
        presenter.present(PetEvent(state: .suspected, escalationStage: 0, line: "", prompt: prompt))

        presenter.dismissPrompt()

        #expect(presenter.pendingPrompt == nil)
        #expect(recorder.answers.isEmpty)
    }

    @Test("回答は一度しか伝わらない")
    func answersPromptOnlyOnce() {
        let presenter = makePresenter()
        let recorder = AnswerRecorder()
        let prompt = PetYesNoPrompt(question: "作業中？") { recorder.record($0) }
        presenter.present(PetEvent(state: .suspected, escalationStage: 0, line: "", prompt: prompt))

        presenter.answerPrompt(true)
        presenter.answerPrompt(false)

        #expect(recorder.answers == [true])
        #expect(presenter.pendingPrompt == nil)
    }

    @Test("監視を止めているあいだと休憩中は静止させる")
    func freezesWhileNotWatching() {
        let presenter = makePresenter()

        presenter.setMonitoring(.paused)
        #expect(presenter.monitoringMode == .paused)
        #expect(presenter.controller.isFrozen)

        presenter.setMonitoring(.onBreak)
        #expect(presenter.controller.isFrozen)

        presenter.setMonitoring(.watching)
        #expect(!presenter.controller.isFrozen)
    }
}
