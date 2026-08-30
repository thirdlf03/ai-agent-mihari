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

        presenter.present(PetEvent(state: .suspected, escalationStage: 1, line: "まだ作業中？"))

        #expect(presenter.lastDirective.fixedAnimation == .waiting)
        #expect(presenter.lastDirective.line == "まだ作業中？")
    }

    @Test("晒し以降は failed に固定する")
    func confirmedFixesFailed() {
        let presenter = makePresenter()

        presenter.present(
            PetEvent(state: .confirmed, escalationStage: PetEvent.exposingStage, line: "晒すね")
        )

        #expect(presenter.lastDirective.fixedAnimation == .failed)
        #expect(presenter.lastDirective.line == "晒すね")
    }

    @Test("疑いの段が上がったときだけ跳ねる")
    func jumpsWhenSuspectStageRises() {
        let presenter = makePresenter()

        presenter.present(PetEvent(state: .suspected, escalationStage: 1, line: "疑い 1"))
        #expect(presenter.lastDirective.playOnce == .jumping)

        presenter.present(PetEvent(state: .suspected, escalationStage: 1, line: "疑い 1 のまま"))
        #expect(presenter.lastDirective.playOnce == nil)

        presenter.present(PetEvent(state: .suspected, escalationStage: 2, line: "疑い 2"))
        #expect(presenter.lastDirective.playOnce == .jumping)
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

        presenter.present(
            PetEvent(state: .confirmed, escalationStage: PetEvent.exposingStage, line: "晒し")
        )
        #expect(presenter.lastDirective.playOnce == .jumping)
    }

    @Test("メンヘラモードは晒しの続きなので跳ね直さない")
    func clingyDoesNotJumpAgain() {
        let presenter = makePresenter()

        presenter.present(
            PetEvent(state: .confirmed, escalationStage: PetEvent.exposingStage, line: "晒し")
        )
        #expect(presenter.lastDirective.playOnce == .jumping)

        presenter.present(
            PetEvent(state: .confirmed, escalationStage: PetEvent.clingyStage, line: "メンヘラ")
        )
        #expect(presenter.lastDirective.playOnce == nil)
        #expect(presenter.lastDirective.fixedAnimation == .failed)
    }

    @Test("正常に戻るときも、セリフが載っていれば吹き出しに出す")
    func normalCanCarryALine() {
        let presenter = makePresenter()
        presenter.present(
            PetEvent(state: .confirmed, escalationStage: PetEvent.clingyStage, line: "まだ戻らないの?")
        )

        presenter.present(PetEvent(state: .normal, escalationStage: 0, line: "やっと戻ってきた。"))

        #expect(presenter.lastDirective.playOnce == .waving)
        #expect(presenter.lastDirective.line == "やっと戻ってきた。")
    }

    @Test("正常に戻ると固定を解いて一度だけ手を振る")
    func wavesWhenBackToNormal() {
        let presenter = makePresenter()
        presenter.present(PetEvent(state: .suspected, escalationStage: 1, line: "まだ作業中？"))

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
        presenter.present(PetEvent(state: .suspected, escalationStage: 2, line: "", prompt: prompt))
        #expect(presenter.pendingPrompt != nil)

        presenter.present(PetEvent(state: .suspected, escalationStage: 2, line: "まだいる？"))

        #expect(presenter.pendingPrompt != nil)
        #expect(presenter.lastDirective.fixedAnimation == .waiting)
    }

    @Test("dismissPrompt で問いかけを捨てる。回答は呼ばない")
    func dismissPromptDropsPrompt() {
        let presenter = makePresenter()
        let recorder = AnswerRecorder()
        let prompt = PetYesNoPrompt(question: "作業中？") { recorder.record($0) }
        presenter.present(PetEvent(state: .suspected, escalationStage: 2, line: "", prompt: prompt))

        presenter.dismissPrompt()

        #expect(presenter.pendingPrompt == nil)
        #expect(recorder.answers.isEmpty)
    }

    @Test("問いかけを出しているあいだは、届いたセリフの音声も鳴らさずに待たせる")
    func heldLineKeepsItsAudioUntilThePromptCloses() {
        // 音声だけ先に鳴ると、問いかけが閉じたあとに無音の吹き出しだけが出る。
        let presenter = makePresenter()
        let recorder = AnswerRecorder()
        let audio = Data("wav".utf8)
        let prompt = PetYesNoPrompt(question: "休憩中?") { recorder.record($0) }
        presenter.present(PetEvent(state: .suspected, escalationStage: 2, line: "", prompt: prompt))

        presenter.present(
            PetEvent(state: .confirmed, escalationStage: 4, line: "サボってる?", audio: audio)
        )
        #expect(presenter.controller.lastPreparedAudio == nil)

        presenter.dismissPrompt()

        #expect(presenter.controller.lastPreparedAudio == audio)
    }

    @Test("回答は一度しか伝わらない")
    func answersPromptOnlyOnce() {
        let presenter = makePresenter()
        let recorder = AnswerRecorder()
        let prompt = PetYesNoPrompt(question: "作業中？") { recorder.record($0) }
        presenter.present(PetEvent(state: .suspected, escalationStage: 2, line: "", prompt: prompt))

        presenter.answerPrompt(true)
        presenter.answerPrompt(false)

        #expect(recorder.answers == [true])
        #expect(presenter.pendingPrompt == nil)
    }

    @Test("問いかけに音声が付いていれば、出した瞬間に鳴らす")
    func promptPlaysItsAudio() {
        let presenter = makePresenter()
        let recorder = AnswerRecorder()
        let audio = Data("m4a".utf8)
        let prompt = PetYesNoPrompt(question: "作業中？", audio: audio) { recorder.record($0) }

        presenter.present(PetEvent(state: .suspected, escalationStage: 2, line: "", prompt: prompt))

        #expect(presenter.controller.lastPreparedAudio == audio)
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

    @Test("監視が始まると作業開始の一言を言う")
    func speaksWhenWatchingStarts() {
        let presenter = makePresenter()
        presenter.setMonitoring(.paused)

        presenter.setMonitoring(.watching)

        #expect(presenter.controller.lastSpokenKind == .watchStart)
    }

    @Test("監視中のまま入れ直しても言い直さない")
    func staysQuietWhenWatchingIsSetAgain() {
        let presenter = makePresenter()

        presenter.setMonitoring(.watching)

        #expect(presenter.controller.lastSpokenKind == nil)
    }

    @Test("休憩明けは休憩おわりの一言を言い、入れ直しても言い直さない")
    func speaksBreakEndWhenBreakFinishes() {
        let presenter = makePresenter()
        presenter.setMonitoring(.onBreak)

        presenter.setMonitoring(.watching)
        #expect(presenter.controller.lastSpokenKind == .breakEnd)

        // 言い直していれば watchStart に変わる。
        presenter.setMonitoring(.watching)
        #expect(presenter.controller.lastSpokenKind == .breakEnd)
    }
}
