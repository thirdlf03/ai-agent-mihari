import Foundation
import SwiftUI
import os

/// セリフを作らせて喋らせる。
///
/// セリフ生成も読み上げも、失敗しても検知や送信を止めない。
/// ここで投げた例外が上に抜けると、サボりを見つけたのに何も起きない、という壊れ方をする。
@MainActor
public final class VoiceController: ObservableObject {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "voice")

    /// 画面に残す発話の件数。
    public static let historyLimit = 20

    /// 1 回の発話の記録。
    public struct Utterance: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let text: String
        public let fromLLM: Bool
        public let spokenAloud: Bool
        public let note: String?
        public let at: Date
        /// スクショを添えたときに読み取れた画面。読ませていなければ `nil`。
        public let screen: SpokenLine.ScreenReading?
        /// スクショを送ったのに読めなかった理由。
        public let screenError: String?
    }

    @Published public private(set) var status: VoiceStatus?
    @Published public private(set) var history: [Utterance] = []
    @Published public private(set) var lastError: String?
    @Published public private(set) var isSpeaking = false

    private let player: SpeechPlayer

    public init(player: SpeechPlayer = SpeechPlayer()) {
        self.player = player
        // 自然に喋り終わったときに `isSpeaking` を戻す。
        // これが無いと、一度喋ったきり「喋っている」ままになる。
        player.onPlaybackFinished = { [weak self] priority in
            Task { @MainActor in
                self?.handlePlaybackFinished(priority: priority)
            }
        }
    }

    /// セリフ生成と読み上げが使える状態かを取り直す。
    public func refreshStatus(using client: DaemonClient?) async {
        guard let client else {
            status = nil
            lastError = DaemonError.notRunning.errorDescription
            return
        }
        do {
            status = try await client.voiceStatus()
            lastError = nil
        } catch {
            status = nil
            lastError = describe(error)
        }
    }

    /// 状況を渡してセリフを作らせる。**鳴らすのは呼び出し側に任せる。**
    ///
    /// 検知のセリフは、取れた瞬間ではなくペットの吹き出しが出る瞬間に鳴らしたい。
    /// そのため取得だけをここで済ませ、音声は `SpokenLine` に載せたまま返す。
    ///
    /// - Returns: 作れたセリフ。作れなかったときは `nil`。
    public func fetchLine(_ request: SpeechRequest, using client: DaemonClient?) async -> SpokenLine? {
        guard let client else {
            lastError = DaemonError.notRunning.errorDescription
            return nil
        }

        let line: SpokenLine
        do {
            line = try await client.speak(request)
            lastError = nil
        } catch {
            // ここで諦める。喋れないだけで、呼び出し元の処理は続く。
            lastError = describe(error)
            Self.logger.error("セリフを取得できなかった: \(self.lastError ?? "", privacy: .public)")
            return nil
        }

        logScreen(line)
        logVoice(line)
        // 実際に鳴らすのは呼び出し側なので、ここでは音声が付いてきたかどうかを記録する。
        record(line, spokenAloud: line.audioData != nil)
        return line
    }

    /// 状況を渡してセリフを作らせ、音声があればその場で鳴らす。
    ///
    /// - Returns: 喋った(または表示した)セリフ。作れなかったときは `nil`。
    @discardableResult
    public func speak(_ request: SpeechRequest, using client: DaemonClient?) async -> String? {
        guard let line = await fetchLine(request, using: client) else { return nil }
        if !playIfPossible(line) {
            Self.logger.warning("鳴らせなかった: \(line.text, privacy: .public)")
        }
        return line.text
    }

    /// 画面を読ませた結果をログに残す。
    ///
    /// セリフだけ見ても「何を見て言ったのか」が分からない。読めなかったときも
    /// 黙って画面情報なしのセリフになるだけなので、理由を残さないと気付けない。
    private func logScreen(_ line: SpokenLine) {
        if let screen = line.screen {
            Self.logger.info(
                "画面: \(screen.app ?? "不明", privacy: .public) / \(screen.category, privacy: .public) / \(screen.activity, privacy: .public)"
            )
        }
        if let screenError = line.screenError {
            Self.logger.warning("画面を読めなかった: \(screenError, privacy: .public)")
        }
    }

    /// セリフと音声がどう作られたかをログに残す。
    ///
    /// 音声が付いてこなくても、固定文言に落ちても、画面には同じようにセリフが並ぶ。
    /// 理由を残さないと「なぜか喋らない」で終わってしまう。
    private func logVoice(_ line: SpokenLine) {
        if let audioError = line.audioError {
            Self.logger.warning("音声が付いてこなかった: \(audioError, privacy: .public)")
        }
        if let fallbackReason = line.fallbackReason {
            Self.logger.info("固定文言に落ちた: \(fallbackReason, privacy: .public)")
        }
    }

    /// 喋っている途中で止める。オーバーレイの解除などから使う。
    public func stopSpeaking() {
        player.stop()
        isSpeaking = false
    }

    /// 喋り終わったときの後始末。`SpeechPlayer` の自然終了だけがここに来る。
    ///
    /// ひとりごとが終わっただけなら、検知のセリフの状態は動かさない。
    func handlePlaybackFinished(priority: SpeechPriority) {
        guard priority == .detection else { return }
        isSpeaking = false
    }

    private func playIfPossible(_ line: SpokenLine) -> Bool {
        guard let wav = line.audioData else { return false }
        // 検知のセリフは最優先。ひとりごとが鳴っていても割り込んで鳴らす。
        let played = player.play(wav: wav, priority: .detection)
        isSpeaking = played
        return played
    }

    /// 履歴の積み方だけをテストから確かめるための入口。
    func recordForTesting(_ line: SpokenLine, spokenAloud: Bool) {
        record(line, spokenAloud: spokenAloud)
    }

    /// 喋っている状態からの遷移をテストから確かめるための入口。
    /// 実際の再生は音声デバイスを必要とするため、状態だけを立てる。
    func markSpeakingForTesting() {
        isSpeaking = true
    }

    private func record(_ line: SpokenLine, spokenAloud: Bool) {
        history.insert(
            Utterance(
                text: line.text,
                fromLLM: line.fromLLM,
                spokenAloud: spokenAloud,
                note: line.audioError ?? line.fallbackReason,
                at: Date(),
                screen: line.screen,
                screenError: line.screenError
            ),
            at: 0
        )
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? DaemonError)?.errorDescription ?? error.localizedDescription
    }
}
