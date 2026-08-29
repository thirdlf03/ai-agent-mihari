import Foundation
import Testing

@testable import MihariCore

@Suite("音楽が鳴っているときだけ説教する")
struct MusicGateJudgeTests {

    private let judge = DetectionJudge(thresholds: .default)

    private func signals(music: NowPlaying) -> DetectionSignals {
        DetectionSignals(macIdleSeconds: 600, music: music)
    }

    @Test("音楽が鳴っていれば、音楽を止めて画面を覆う")
    func playingMusicTriggersSermon() {
        let decision = judge.decide(signals(music: .playing(.spotify)))
        #expect(decision.state == .confirmed)
        #expect(decision.shouldInterrupt)
    }

    @Test("何も鳴っていなければ画面を覆わない")
    func silenceDoesNotInterrupt() {
        // 止める音楽が無いのに画面を奪っても、「音楽を止めて聞かせる」が空振りするだけ。
        let decision = judge.decide(signals(music: .silent))
        #expect(decision.state == .confirmed)
        #expect(decision.shouldInterrupt == false)
    }

    @Test("画面を覆わなくても、声はかけるし証拠は取る")
    func silenceStillSpeaksAndCaptures() {
        let decision = judge.decide(signals(music: .silent))
        #expect(decision.shouldSpeak)
        #expect(decision.evidence == .macCamera)
    }

    @Test("再生状況が分からないときは画面を覆わない")
    func undeterminedDoesNotInterrupt() {
        // オートメーション権限が無いと状態が取れない。確信が無いのに画面は奪わない。
        let decision = judge.decide(signals(music: .undetermined(reason: "権限が無い")))
        #expect(decision.shouldInterrupt == false)
    }

    @Test("鳴っているプレイヤー名が判断の根拠に残る")
    func reasonNamesThePlayer() {
        let reason = judge.decide(signals(music: .playing(.spotify))).reason
        #expect(reason.contains("Spotify"))
    }

    @Test("鳴っていなければ根拠に音楽の話は出ない")
    func silentReasonOmitsMusic() {
        #expect(!judge.decide(signals(music: .silent)).reason.contains("再生中"))
    }

    @Test("Music で鳴っていても同じように説教する")
    func appleMusicAlsoTriggers() {
        #expect(judge.decide(signals(music: .playing(.music))).shouldInterrupt)
    }
}

@Suite("いま鳴っているかの表現")
struct NowPlayingTests {

    @Test("鳴っていると確信できるのは playing のときだけ")
    func onlyPlayingCounts() {
        #expect(NowPlaying.playing(.spotify).isPlaying)
        #expect(NowPlaying.silent.isPlaying == false)
        // 「分からない」を「鳴っていない」と混ぜない。権限が無い人に説教が
        // 一切出なくなるのと、勝手に画面を奪われるのは別の話。
        #expect(NowPlaying.undetermined(reason: "x").isPlaying == false)
    }

    @Test("画面に出す文言にプレイヤー名が入る")
    func labelNamesThePlayer() {
        #expect(NowPlaying.playing(.spotify).label.contains("Spotify"))
        #expect(NowPlaying.silent.label.contains("鳴っていない"))
        #expect(NowPlaying.undetermined(reason: "x").label.contains("オートメーション"))
    }
}

@Suite("音楽を見に行く条件")
@MainActor
struct MusicProbeTests {

    /// 何回問い合わされたかを数える。
    private final class MusicSpy: MusicControlling, @unchecked Sendable {
        private let lock = NSLock()
        private var _queries = 0
        var queries: Int { lock.withLock { _queries } }
        var answer: NowPlaying = .playing(.spotify)

        func nowPlaying() async -> NowPlaying {
            lock.withLock { _queries += 1 }
            return answer
        }
        func stopPlaying() async -> MusicStopOutcome { .nothingWasPlaying }
        func resumePlaying(_ outcome: MusicStopOutcome) async {}
    }

    private func engine(idle: TimeInterval, music: MusicSpy) -> DetectionEngine {
        DetectionEngine(idleMonitor: MacIdleMonitor(probe: { idle }), musicController: music)
    }

    @Test("手を動かしている間は音楽を見に行かない")
    func neverProbesWhileActive() async {
        // 何も起きない場面で他アプリに毎秒話しかける理由がない。
        let music = MusicSpy()
        _ = await engine(idle: 10, music: music).currentSignals()
        #expect(music.queries == 0)
    }

    @Test("無操作になったら音楽を見に行く")
    func probesOnceIdle() async {
        let music = MusicSpy()
        let signals = await engine(idle: 200, music: music).currentSignals()
        #expect(music.queries == 1)
        #expect(signals.music == .playing(.spotify))
    }

    @Test("止めると音楽の状態も忘れる")
    func stopClearsMusic() async {
        let music = MusicSpy()
        let engine = engine(idle: 200, music: music)
        _ = await engine.currentSignals()
        #expect(engine.music.isPlaying)

        engine.stop()

        #expect(engine.music == .silent)
    }
}
