import Foundation
import Testing

@testable import MihariCore

@Suite("セリフの読み上げ")
@MainActor
struct VoiceControllerTests {

    private func line(_ text: String, fromLLM: Bool = true, audioError: String? = nil) -> SpokenLine {
        SpokenLine(text: text, fromLLM: fromLLM, fallbackReason: nil, audio: nil, audioError: audioError)
    }

    @Test("デーモンが動いていなければ喋らず、理由が残る")
    func withoutDaemon() async {
        let controller = VoiceController()

        let spoken = await controller.speak(SpeechRequest(idleSeconds: 60), using: nil)

        #expect(spoken == nil)
        #expect(controller.lastError == DaemonError.notRunning.errorDescription)
        #expect(controller.history.isEmpty)
    }

    @Test("デーモンが動いていなければ状態も取れない")
    func statusWithoutDaemon() async {
        let controller = VoiceController()
        await controller.refreshStatus(using: nil)
        #expect(controller.status == nil)
        #expect(controller.lastError == DaemonError.notRunning.errorDescription)
    }

    @Test("履歴は上限を超えると古いものから消える")
    func historyIsCapped() {
        let controller = VoiceController()
        for index in 0...(VoiceController.historyLimit + 5) {
            controller.recordForTesting(line("\(index)"), spokenAloud: false)
        }
        #expect(controller.history.count == VoiceController.historyLimit)
        // 新しい方が先頭に来る。
        #expect(controller.history.first?.text == "\(VoiceController.historyLimit + 5)")
    }

    @Test("音声が作れなかった理由は履歴に残る")
    func audioErrorIsKept() {
        let controller = VoiceController()
        controller.recordForTesting(line("やあ", audioError: "VOICEVOX に繋がらない"), spokenAloud: false)

        let utterance = controller.history.first
        #expect(utterance?.spokenAloud == false)
        #expect(utterance?.note == "VOICEVOX に繋がらない")
    }

    @Test("止めると喋っていない状態になる")
    func stopClearsSpeaking() {
        let controller = VoiceController()
        controller.stopSpeaking()
        #expect(controller.isSpeaking == false)
    }
}
