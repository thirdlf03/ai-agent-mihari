import Foundation
import SwiftUI
import os

/// 音楽を止めて全画面オーバーレイを出し、説教を聞かせてから必ず自分で解除する。
///
/// **最優先の要件は「解除されないと Mac が操作不能になる」を絶対に起こさないこと。**
/// そのため `show()` は他の何よりも先に上限秒数のタイマー(`scheduleHardDeadline`)を仕込む。
/// 音楽停止・セリフ取得・読み上げはすべて「失敗しても投げっぱなしにしない」形にしてあり、
/// 途中で何が起きても最終的にこのタイマーが `dismiss(reason: .timeLimit)` を呼ぶ。
///
/// `NSWindow` の生成や `NSApplication.presentationOptions` の変更は行わない。
/// それらは `OverlayWindowPresenting` の裏に隠してあり、テストではスタブを注入する。
@MainActor
public final class OverlayModel: ObservableObject {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "overlay")

    /// 上限秒数の既定値。これを超えたら読み上げの途中でも必ず解除する。
    public static let defaultMaxDurationSeconds = 90
    /// 画面のスライダー/Stepper が許す範囲。
    public static let durationRange = 10...300
    /// 見積もり読了時間の下限。極端に短いセリフでも一瞬で消えないようにする。
    static let minimumSpeechDisplaySeconds = 3
    /// セリフの文字数から読み上げ時間を見積もるときの目安(文字/秒)。
    static let charactersPerSecondEstimate = 6.0
    /// 画面に残す実行ログの件数。
    public static let logHistoryLimit = 30
    /// セリフを取得できなかったときに表示する固定文言。
    public static let fallbackSermonLine = "サボりが確定した。音楽は止めた。ここで最後まで聞いてから戻ってくること。"
    /// 「試す」ボタンが使う既定の状況(サボり確定 = 説教段階)。
    public static let defaultSermonRequest = SpeechRequest(idleSeconds: 900, escalation: .warn)

    /// セリフを取得して(可能なら)読み上げさせる関数。`VoiceController.speak` を包んで渡す想定。
    /// 例外を投げても `OverlayModel` 側で吸収し、固定文言に倒して続行する。
    public typealias SermonSpeaking = (SpeechRequest) async throws -> String?
    /// タイマーの待ち方。本番は `Task.sleep`、テストでは短時間で解決するものに差し替える。
    public typealias Sleeping = (Duration) async -> Void

    @Published public var maxDurationSeconds: Int

    /// 解除したあと、止めた音楽を再開するか。
    ///
    /// **既定は再開しない。** サボって音楽を聴いていた相手に、説教のあと音楽を
    /// 返してやる理由がない。聴き直したければ本人が再生すればよい。
    @Published public var resumeMusicAfterDismiss: Bool
    @Published public private(set) var isPresented = false
    @Published public private(set) var lastDismissReason: OverlayDismissReason?
    @Published public private(set) var lastMusicOutcome: MusicStopOutcome?
    @Published public private(set) var log: [OverlayLogEntry] = []

    private let presenter: OverlayWindowPresenting
    private let musicController: MusicControlling
    private let speak: SermonSpeaking
    private let stopSpeaking: () -> Void
    private let sleep: Sleeping

    private var sermonTask: Task<Void, Never>?
    private var hardDeadlineTask: Task<Void, Never>?
    private var speechDeadlineTask: Task<Void, Never>?
    /// 解除後の音楽再開を、テストが完了を待てるように保持しておく。
    private(set) var resumeTask: Task<Void, Never>?

    /// - Parameters:
    ///   - presenter: 全画面ウィンドウの表示 / 解除。テストではスタブを渡す。
    ///   - musicController: 音楽を止める / 再開する処理。既定は AppleScript + メディアキー実装。
    ///   - maxDurationSeconds: 上限秒数。名前付き定数 `defaultMaxDurationSeconds` を既定にしつつ、
    ///     テストからは短い値を注入できる。
    ///   - speak: セリフの取得(と読み上げの開始)。既定は「何も喋らない」。`OverlayView` からは
    ///     `VoiceController.speak` を包んだものを渡す。
    ///   - stopSpeaking: 読み上げを止める処理。既定は何もしない。`OverlayView` からは
    ///     `VoiceController.stopSpeaking` を渡す。
    ///   - sleep: タイマーの待機処理。テストは実際の秒数を待たずに済むものへ差し替える。
    public init(
        presenter: OverlayWindowPresenting,
        musicController: MusicControlling = AppleScriptMusicController(),
        maxDurationSeconds: Int = OverlayModel.defaultMaxDurationSeconds,
        resumeMusicAfterDismiss: Bool = false,
        speak: @escaping SermonSpeaking = { _ in nil },
        stopSpeaking: @escaping () -> Void = {},
        sleep: @escaping Sleeping = { try? await Task.sleep(for: $0) }
    ) {
        self.presenter = presenter
        self.musicController = musicController
        self.maxDurationSeconds = maxDurationSeconds
        self.resumeMusicAfterDismiss = resumeMusicAfterDismiss
        self.speak = speak
        self.stopSpeaking = stopSpeaking
        self.sleep = sleep
    }

    /// 説教オーバーレイを開始する。すでに表示中なら何もしない(二重表示防止)。
    public func show(request: SpeechRequest = OverlayModel.defaultSermonRequest) {
        guard !isPresented else {
            appendLog("すでに表示中なので無視した(二重起動防止)")
            return
        }
        isPresented = true
        lastDismissReason = nil
        appendLog("説教オーバーレイを開始する(上限 \(maxDurationSeconds) 秒)")

        // 安全策その1: 何より先にこの上限タイマーを仕込む。
        // 以降の処理がどれだけ失敗・停滞しても、これだけは動き続けて必ず解除する。
        scheduleHardDeadline()

        sermonTask = Task { [weak self] in
            await self?.runSermonFlow(request: request)
        }
    }

    /// 画面の「いますぐ解除」ボタンなど、明示的な解除。
    public func dismissManually() {
        dismiss(reason: .manual)
    }

    private func runSermonFlow(request: SpeechRequest) async {
        let outcome = await musicController.stopPlaying()
        lastMusicOutcome = outcome
        appendLog("音楽: \(outcome.summary)")

        let text = await fetchSermonLineSafely(request: request)

        // ここまでの間に上限タイマーが先に解除していたら、いまさら表示は出さない。
        guard isPresented else { return }

        presenter.present(text: text) { [weak self] in
            self?.dismiss(reason: .escape)
        }
        appendLog("セリフ: \(text)")
        scheduleSpeechDeadline(for: text)
    }

    /// `speak` は呼び出し側の注入なので、何が起きても(例外を投げても)ここで必ず吸収する。
    /// セリフが読み上げに失敗しても、オーバーレイ自体は固定文言で表示を続ける。
    private func fetchSermonLineSafely(request: SpeechRequest) async -> String {
        do {
            if let line = try await speak(request), !line.isEmpty {
                return line
            }
        } catch {
            Self.logger.error("セリフの取得で例外が発生した: \(String(describing: error), privacy: .public) → 固定文言で続行する")
            appendLog("セリフの取得で例外が発生した。固定文言で続行する")
        }
        return Self.fallbackSermonLine
    }

    private func scheduleHardDeadline() {
        hardDeadlineTask?.cancel()
        let seconds = maxDurationSeconds
        hardDeadlineTask = Task { [weak self, sleep] in
            await sleep(.seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss(reason: .timeLimit)
        }
    }

    private func scheduleSpeechDeadline(for text: String) {
        let seconds = Self.estimatedReadingSeconds(for: text)
        speechDeadlineTask?.cancel()
        speechDeadlineTask = Task { [weak self, sleep] in
            await sleep(.seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss(reason: .speechFinished)
        }
    }

    /// 文字数から読み上げの所要時間を見積もる。
    ///
    /// `VoiceController.isSpeaking` は自然に喋り終わっても `false` に戻るが、解除の判定は
    /// 従来どおり文字数からの見積もりで行う。見積もった時間を「読み上げ完了」とみなし、
    /// 見積もりが外れて長引いても、上限秒数のタイマーが必ず先に効く。
    static func estimatedReadingSeconds(for text: String) -> Int {
        let raw = Double(text.count) / charactersPerSecondEstimate
        return max(minimumSpeechDisplaySeconds, Int(raw.rounded(.up)))
    }

    /// 解除する。何度呼ばれても安全(表示中でなければ何もしない)。
    private func dismiss(reason: OverlayDismissReason) {
        guard isPresented else { return }

        hardDeadlineTask?.cancel()
        hardDeadlineTask = nil
        speechDeadlineTask?.cancel()
        speechDeadlineTask = nil
        sermonTask?.cancel()
        sermonTask = nil

        stopSpeaking()
        presenter.dismiss()

        if resumeMusicAfterDismiss, let outcome = lastMusicOutcome {
            let musicController = self.musicController
            resumeTask = Task { await musicController.resumePlaying(outcome) }
        }

        isPresented = false
        lastDismissReason = reason
        appendLog("解除した(理由: \(reason.label))")
    }

    private func appendLog(_ message: String) {
        log.insert(OverlayLogEntry(message: message), at: 0)
        if log.count > Self.logHistoryLimit {
            log.removeLast(log.count - Self.logHistoryLimit)
        }
    }

    /// テストが、解除後に走る音楽再開タスクの完了を待つための入口。
    func waitForResumeForTesting() async {
        await resumeTask?.value
    }

    /// テストが `show()` 直後の一連の処理(音楽停止 → セリフ取得 → 表示 → タイマー予約)の
    /// 完了を待つための入口。実時間の sleep でタイミングを図ると、他のテストと並列実行された
    /// ときの CPU 混雑で簡単にフラフラになるため、こちらを使う。
    func waitForSermonSetupForTesting() async {
        await sermonTask?.value
    }
}
