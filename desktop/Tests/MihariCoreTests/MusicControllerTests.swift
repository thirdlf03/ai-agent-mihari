import Testing

@testable import MihariCore

@Suite("音楽の停止と再開")
struct MusicControllerTests {

    /// AppleScript を実際には動かさず、決めた戻り値を返すスタブ。
    private final class StubRunner: AppleScriptRunning, @unchecked Sendable {
        var responses: [String: AppleScriptOutcome] = [:]
        private(set) var calls: [String] = []

        func run(_ source: String) -> AppleScriptOutcome {
            calls.append(source)
            return responses[source] ?? AppleScriptOutcome(errorNumber: -600)
        }
    }

    /// 実際に CGEvent を送らず、呼ばれた回数だけ数えるスタブ。
    private final class StubMediaKeySender: MediaKeySending, @unchecked Sendable {
        private(set) var toggleCount = 0
        func sendPlayPauseToggle() { toggleCount += 1 }
    }

    @Test("再生中のプレイヤーが見つかれば AppleScript の pause で止める")
    func stopsPlayingPlayerViaAppleScript() async {
        let runner = StubRunner()
        runner.responses["tell application \"Music\" to player state as text"] = AppleScriptOutcome(value: "playing")
        runner.responses["tell application \"Music\" to pause"] = AppleScriptOutcome(value: "")
        let mediaKey = StubMediaKeySender()
        let controller = AppleScriptMusicController(
            runner: runner,
            mediaKeySender: mediaKey,
            isRunning: { $0 == MediaPlayerKind.music.bundleID }
        )

        let outcome = await controller.stopPlaying()

        #expect(outcome == .stoppedViaAppleScript(player: .music))
        #expect(mediaKey.toggleCount == 0)
    }

    @Test("pause コマンド自体が失敗したら、メディアキーにフォールバックする")
    func fallsBackToMediaKeyWhenPauseFails() async {
        let runner = StubRunner()
        runner.responses["tell application \"Music\" to player state as text"] = AppleScriptOutcome(value: "playing")
        runner.responses["tell application \"Music\" to pause"] = AppleScriptOutcome(
            errorNumber: AppleScriptOutcome.automationNotPermitted
        )
        let mediaKey = StubMediaKeySender()
        let controller = AppleScriptMusicController(
            runner: runner,
            mediaKeySender: mediaKey,
            isRunning: { $0 == MediaPlayerKind.music.bundleID }
        )

        let outcome = await controller.stopPlaying()

        #expect(outcome == .stoppedViaMediaKey)
        #expect(mediaKey.toggleCount == 1)
    }

    @Test("誰も再生していないと確認できたら、メディアキーは送らない(誤って再生を始めないため)")
    func doesNothingWhenNothingIsPlaying() async {
        let runner = StubRunner()
        runner.responses["tell application \"Music\" to player state as text"] = AppleScriptOutcome(value: "paused")
        let mediaKey = StubMediaKeySender()
        let controller = AppleScriptMusicController(
            runner: runner,
            mediaKeySender: mediaKey,
            isRunning: { $0 == MediaPlayerKind.music.bundleID }
        )

        let outcome = await controller.stopPlaying()

        #expect(outcome == .nothingWasPlaying)
        #expect(mediaKey.toggleCount == 0)
    }

    @Test("何も起動していなければ、AppleScript もメディアキーも使わない")
    func doesNothingWhenNoPlayerIsRunning() async {
        let runner = StubRunner()
        let mediaKey = StubMediaKeySender()
        let controller = AppleScriptMusicController(runner: runner, mediaKeySender: mediaKey, isRunning: { _ in false })

        let outcome = await controller.stopPlaying()

        #expect(outcome == .nothingWasPlaying)
        #expect(runner.calls.isEmpty)
        #expect(mediaKey.toggleCount == 0)
    }

    @Test("オートメーション権限が無く状態を確認できないときは、メディアキーを送らずに失敗として扱う")
    func reportsFailureWithoutSendingMediaKeyWhenPermissionDenied() async {
        let runner = StubRunner()
        runner.responses["tell application \"Music\" to player state as text"] = AppleScriptOutcome(
            errorNumber: AppleScriptOutcome.automationNotPermitted
        )
        let mediaKey = StubMediaKeySender()
        let controller = AppleScriptMusicController(
            runner: runner,
            mediaKeySender: mediaKey,
            isRunning: { $0 == MediaPlayerKind.music.bundleID }
        )

        let outcome = await controller.stopPlaying()

        guard case .couldNotStop = outcome else {
            Issue.record("couldNotStop になるはず: \(outcome)")
            return
        }
        #expect(mediaKey.toggleCount == 0)
    }

    @Test("解除後、AppleScript で止めた分は AppleScript で再開する")
    func resumesViaAppleScript() async {
        let runner = StubRunner()
        runner.responses["tell application \"Music\" to play"] = AppleScriptOutcome(value: "")
        let controller = AppleScriptMusicController(
            runner: runner,
            mediaKeySender: StubMediaKeySender(),
            isRunning: { _ in false }
        )

        await controller.resumePlaying(.stoppedViaAppleScript(player: .music))

        #expect(runner.calls.contains("tell application \"Music\" to play"))
    }

    @Test("解除後、メディアキーで止めた分はメディアキーで再開する")
    func resumesViaMediaKey() async {
        let mediaKey = StubMediaKeySender()
        let controller = AppleScriptMusicController(
            runner: StubRunner(),
            mediaKeySender: mediaKey,
            isRunning: { _ in false }
        )

        await controller.resumePlaying(.stoppedViaMediaKey)

        #expect(mediaKey.toggleCount == 1)
    }

    @Test("何もしていなかったときは再開時も何もしない")
    func resumeDoesNothingForNothingWasPlaying() async {
        let mediaKey = StubMediaKeySender()
        let runner = StubRunner()
        let controller = AppleScriptMusicController(runner: runner, mediaKeySender: mediaKey, isRunning: { _ in false })

        await controller.resumePlaying(.nothingWasPlaying)

        #expect(mediaKey.toggleCount == 0)
        #expect(runner.calls.isEmpty)
    }
}
