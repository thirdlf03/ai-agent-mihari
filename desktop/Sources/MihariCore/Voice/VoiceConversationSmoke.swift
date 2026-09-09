import Foundation
import os

/// §5-1: 固定短文 → VOICEVOX 合成 → 再生 の 1 往復を試す煙テスト。
///
/// room / OpenAI / ペット UI は不要。モック応答文をその場で合成し、
/// アプリ共有の `SpeechPlayer` から鳴らす。優先度は `.chatter` なので、
/// 検知のセリフが鳴っているあいだは譲る。
enum VoiceConversationSmoke {
    /// 煙テスト用の固定短文(冥鳴ひまり / 話者 14)。
    static let mockReplyText = "こんにちは。VOICEVOX の接続確認です。"

    private static let logger = Logger(
        subsystem: "com.thirdlf03.mihari",
        category: "VoiceConversationSmoke"
    )

    /// テキストを合成して再生する。再生を始められたら `true`。
    @MainActor
    static func runRoundTrip(
        text: String = mockReplyText,
        player: SpeechPlayer,
        client: VoicevoxClient = VoicevoxClient()
    ) async -> Bool {
        do {
            let wave = try await client.synthesize(text: text)
            let played = player.play(audio: wave, priority: .chatter)
            if !played {
                Self.logger.debug("VOICEVOX の合成は成功したが、再生を開始できなかった")
            }
            return played
        } catch {
            Self.logger.debug("VOICEVOX 1往復に失敗: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
