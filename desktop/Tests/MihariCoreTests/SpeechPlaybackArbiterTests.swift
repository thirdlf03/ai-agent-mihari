import Testing

@testable import MihariCore

@Suite("どちらの声を鳴らすか")
struct SpeechPlaybackArbiterTests {

    @Test("検知のセリフは何も鳴っていなくても鳴る")
    func detectionOnSilence() {
        #expect(SpeechPlaybackArbiter.decide(current: nil, requested: .detection) == .play)
    }

    @Test("検知のセリフは鳴っているものを止めてでも鳴る")
    func detectionInterrupts() {
        #expect(SpeechPlaybackArbiter.decide(current: .chatter, requested: .detection) == .play)
        #expect(SpeechPlaybackArbiter.decide(current: .detection, requested: .detection) == .play)
    }

    @Test("ひとりごとは検知のセリフ中なら捨てる")
    func chatterIsDroppedDuringDetection() {
        #expect(SpeechPlaybackArbiter.decide(current: .detection, requested: .chatter) == .drop)
    }

    @Test("ひとりごとは何も鳴っていなければ鳴るし、ひとりごと同士なら差し替える")
    func chatterPlaysOtherwise() {
        #expect(SpeechPlaybackArbiter.decide(current: nil, requested: .chatter) == .play)
        #expect(SpeechPlaybackArbiter.decide(current: .chatter, requested: .chatter) == .play)
    }

    @Test("検知のセリフはひとりごとより強い")
    func detectionOutranksChatter() {
        #expect(SpeechPriority.chatter < SpeechPriority.detection)
    }
}
