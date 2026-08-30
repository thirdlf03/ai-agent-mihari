import Foundation
import Testing

@testable import MihariCore

// 「音楽が鳴っているときだけ画面を奪う」は状態機械側の話になったので、
// その検証は `DetectionExposureTests.interruptsOnlyWhenMusicIsPlaying` に移した。

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
        let engine = DetectionEngine(idleMonitor: MacIdleMonitor(probe: { idle }), musicController: music)
        engine.thresholds = .production
        return engine
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
