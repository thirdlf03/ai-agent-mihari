import Foundation
import Testing

@testable import MihariCore

/// 検知のセリフに付いてきた音声を、ペットが自分で鳴らすところだけを検証する。
/// 実際の再生は音声デバイスを必要とするため、鳴らしに行った音声(`lastPreparedAudio`)で確かめる。
@Suite("ペットのセリフの読み上げ")
@MainActor
struct PetControllerSpeechTests {

    /// 実行のたびに空の UserDefaults を使い、テスト同士が表示設定を共有しないようにする。
    private func makeController() -> PetController {
        let suiteName = "mihari.test.pet.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return PetController(defaults: defaults)
    }

    @Test("用意された音声はペットが鳴らす")
    func preparedAudioIsPlayed() {
        let pet = makeController()
        let audio = Data("wav".utf8)

        pet.say("サボってない?", voice: .prepared(audio, priority: .detection))

        #expect(pet.lastPreparedAudio == audio)
    }

    @Test("読み上げを切っているあいだは用意された音声も鳴らさない")
    func preparedAudioIsSkippedWhileVoiceIsOff() {
        let pet = makeController()
        pet.setVoiceEnabled(false)

        pet.say("サボってない?", voice: .prepared(Data("wav".utf8), priority: .detection))

        #expect(pet.lastPreparedAudio == nil)
    }

    @Test("音声の付いていないセリフでは何も鳴らさない")
    func lineWithoutAudioPlaysNothing() {
        let pet = makeController()

        pet.say("サボってない?", voice: .none)

        #expect(pet.lastPreparedAudio == nil)
    }
}
