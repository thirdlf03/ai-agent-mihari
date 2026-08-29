import Foundation
import Testing

@testable import MihariCore

/// `OverlayModel` の一番大事な要件は「解除されないと Mac が操作不能になる」を起こさないこと。
/// ここでは実際に `NSWindow` は 1 枚も出さず(`StubPresenter` に差し替える)、
/// 「上限秒数」「読み上げ完了(推定)」「例外」「Esc」のどの経路でも必ず解除されることと、
/// 二重に表示しないことを確かめる。
@Suite("説教オーバーレイの解除保証")
@MainActor
struct OverlayModelTests {

    /// 実際に全画面ウィンドウを出さず、呼ばれた回数と引数だけを覚えておくスタブ。
    private final class StubPresenter: OverlayWindowPresenting {
        private(set) var presentCount = 0
        private(set) var dismissCount = 0
        private(set) var lastText: String?
        private(set) var lastOnEscape: (() -> Void)?

        var isPresenting: Bool { presentCount > dismissCount }

        func present(text: String, onEscape: @escaping () -> Void) {
            presentCount += 1
            lastText = text
            lastOnEscape = onEscape
        }

        func dismiss() {
            dismissCount += 1
        }
    }

    private final class StubMusicController: MusicControlling, @unchecked Sendable {
        let outcome: MusicStopOutcome
        private(set) var resumedOutcomes: [MusicStopOutcome] = []

        init(outcome: MusicStopOutcome = .nothingWasPlaying) {
            self.outcome = outcome
        }

        func stopPlaying() async -> MusicStopOutcome { outcome }
        func resumePlaying(_ outcome: MusicStopOutcome) async { resumedOutcomes.append(outcome) }
    }

    /// テストの `maxDurationSeconds` / 見積もり秒数を、実時間を待たずミリ秒に縮めて解決する。
    /// 「N 秒待つ」という相対関係はそのまま保つので、どちらのタイマーが先に発火するかは本番と同じ順序になる。
    private func fastSleep(_ duration: Duration) async {
        let millis = max(1, duration.components.seconds)
        try? await Task.sleep(for: .milliseconds(millis))
    }

    private func makeModel(
        presenter: StubPresenter,
        musicController: MusicControlling = StubMusicController(),
        maxDurationSeconds: Int = 100,
        resumeMusicAfterDismiss: Bool = false,
        speak: @escaping OverlayModel.SermonSpeaking = { _ in "テストのセリフ" }
    ) -> OverlayModel {
        OverlayModel(
            presenter: presenter,
            musicController: musicController,
            maxDurationSeconds: maxDurationSeconds,
            resumeMusicAfterDismiss: resumeMusicAfterDismiss,
            speak: speak,
            sleep: fastSleep
        )
    }

    @Test("上限秒数が経過すると、セリフ取得が終わらなくても必ず解除される")
    func hardDeadlineAlwaysFires() async {
        let presenter = StubPresenter()
        let model = makeModel(
            presenter: presenter,
            maxDurationSeconds: 3,
            speak: { _ in
                // セリフの取得がハングした状況を模す。上限タイマーだけが解除の頼りになる。
                try? await Task.sleep(for: .seconds(3600))
                return "手遅れ"
            }
        )

        model.show()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(model.isPresented == false)
        #expect(model.lastDismissReason == .timeLimit)
    }

    @Test("読み上げの推定時間が経過すると自動で解除される")
    func speechCompletionDismisses() async {
        let presenter = StubPresenter()
        // 上限は長く取り、必ず「読み上げ完了」側が先に効く状況にする。
        let model = makeModel(presenter: presenter, maxDurationSeconds: 100, speak: { _ in "短い" })

        model.show()
        try? await Task.sleep(for: .milliseconds(250))

        #expect(model.isPresented == false)
        #expect(model.lastDismissReason == .speechFinished)
    }

    @Test("セリフの取得で例外が出ても、固定文言で表示され最終的に解除される")
    func dismissesEvenIfSpeakThrows() async {
        struct Boom: Error {}
        let presenter = StubPresenter()
        let model = makeModel(
            presenter: presenter,
            maxDurationSeconds: 100,
            speak: { _ in throw Boom() }
        )

        model.show()
        // まず「例外→固定文言で表示」までを確定的に待つ。CPU が混雑していても揺れない。
        await model.waitForSermonSetupForTesting()
        #expect(presenter.presentCount == 1)
        #expect(presenter.lastText == OverlayModel.fallbackSermonLine)

        // ここから先は推定読了時間の経過を待つタイマーなので、実時間で待つしかない。
        try? await Task.sleep(for: .milliseconds(250))
        #expect(model.isPresented == false)
        #expect(model.lastDismissReason == .speechFinished)
    }

    @Test("Esc キーで即座に緊急解除できる")
    func escapeDismissesImmediately() async {
        let presenter = StubPresenter()
        let model = makeModel(presenter: presenter, maxDurationSeconds: 100)

        model.show()
        // 実時間の sleep でタイミングを図ると、他のテストと並列実行されたときの CPU 混雑で
        // 簡単にフラフラになる。`show()` 直後の一連の処理が終わるのを確定的に待つ。
        await model.waitForSermonSetupForTesting()
        #expect(presenter.isPresenting)

        presenter.lastOnEscape?()

        #expect(model.isPresented == false)
        #expect(model.lastDismissReason == .escape)
        #expect(presenter.dismissCount == 1)
    }

    @Test("表示中にもう一度 show() しても、二重に表示しない")
    func doesNotPresentTwice() async {
        let presenter = StubPresenter()
        let model = makeModel(presenter: presenter, maxDurationSeconds: 100)

        model.show()
        model.show()
        await model.waitForSermonSetupForTesting()

        #expect(presenter.presentCount == 1)
        model.dismissManually()
    }

    @Test("解除は何度呼んでも安全(2 回目以降は何もしない)")
    func dismissIsIdempotent() async {
        let presenter = StubPresenter()
        let model = makeModel(presenter: presenter, maxDurationSeconds: 100)

        model.show()
        await model.waitForSermonSetupForTesting()

        model.dismissManually()
        model.dismissManually()
        presenter.lastOnEscape?()

        #expect(presenter.dismissCount == 1)
        #expect(model.lastDismissReason == .manual)
    }

    @Test("解除後に音楽を再開する設定なら、止めた分だけ再開する")
    func resumesMusicWhenConfigured() async {
        let presenter = StubPresenter()
        let music = StubMusicController(outcome: .stoppedViaAppleScript(player: .music))
        let model = makeModel(
            presenter: presenter,
            musicController: music,
            maxDurationSeconds: 100,
            resumeMusicAfterDismiss: true
        )

        model.show()
        await model.waitForSermonSetupForTesting()
        model.dismissManually()
        await model.waitForResumeForTesting()

        #expect(music.resumedOutcomes == [.stoppedViaAppleScript(player: .music)])
    }

    @Test("解除後に音楽を再開しない設定なら、再開しない")
    func doesNotResumeMusicWhenDisabled() async {
        let presenter = StubPresenter()
        let music = StubMusicController(outcome: .stoppedViaAppleScript(player: .music))
        let model = makeModel(
            presenter: presenter,
            musicController: music,
            maxDurationSeconds: 100,
            resumeMusicAfterDismiss: false
        )

        model.show()
        await model.waitForSermonSetupForTesting()
        model.dismissManually()
        await model.waitForResumeForTesting()

        #expect(music.resumedOutcomes.isEmpty)
    }

    @Test("音楽の停止結果がログと状態に残る")
    func recordsMusicOutcome() async {
        let presenter = StubPresenter()
        let music = StubMusicController(outcome: .couldNotStop(reason: "オートメーション権限が無い"))
        let model = makeModel(presenter: presenter, musicController: music, maxDurationSeconds: 100)

        model.show()
        await model.waitForSermonSetupForTesting()

        #expect(model.lastMusicOutcome == .couldNotStop(reason: "オートメーション権限が無い"))
        model.dismissManually()
    }

    @Test("読み上げの見積もり時間は文字数に応じて増え、下限を割らない")
    func estimatedReadingSecondsHasFloorAndGrows() {
        let empty = OverlayModel.estimatedReadingSeconds(for: "")
        let long = OverlayModel.estimatedReadingSeconds(for: String(repeating: "あ", count: 120))

        #expect(empty == OverlayModel.minimumSpeechDisplaySeconds)
        #expect(long > empty)
    }
}
