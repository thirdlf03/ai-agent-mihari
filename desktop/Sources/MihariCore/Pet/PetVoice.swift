import AVFoundation
import Foundation
import os

/// ローカルの VOICEVOX エンジンでセリフを読み上げる。
/// エンジンが動いていないときは何も鳴らさず、ユーザーには何も見せない。
///
/// 音を出す口はアプリで 1 つ(`SpeechPlayer`)しかない。ここはひとりごと(`.chatter`)として
/// 借りるだけで、検知のセリフが鳴っていれば譲るし、止めるときも検知のセリフには手を出さない。
@MainActor
final class PetVoice {
    /// 失敗してから次に接続を試みるまでの間隔(秒)。
    private static let retryInterval: TimeInterval = 30

    private static let logger = Logger(
        subsystem: "com.thirdlf03.mihari",
        category: "PetVoice"
    )

    /// アプリで唯一の音の出口。検知のセリフと共有する。
    private let player: SpeechPlayer
    /// VOICEVOX への合成口。§5-1 の会話経路と共有する。
    private let voicevox: VoicevoxClient
    /// セリフの世代。合成のあいだに次のセリフが来たかを判定するために使う。
    private var generation = 0
    /// この時刻まではエンジンへ接続しに行かない。エンジンが無いときに毎回待たされるのを防ぐ。
    private var unavailableUntil: Date?

    /// - Parameters:
    ///   - player: 音を出す口。検知のセリフと同じものを渡す。
    ///   - voicevox: VOICEVOX 合成クライアント。テストでは差し替え可能。
    init(player: SpeechPlayer, voicevox: VoicevoxClient = VoicevoxClient()) {
        self.player = player
        self.voicevox = voicevox
    }

    /// セリフを合成して再生する。再生を始められたら音声の長さを返し、鳴らせなければ nil を返す。
    ///
    /// 検知のセリフが鳴っているときは譲って何も鳴らさない。その場合も nil を返すので、
    /// 吹き出しの表示時間は文字数から決めた既定のままになる。
    func speak(_ text: String) async -> TimeInterval? {
        generation += 1
        let currentGeneration = generation
        // 前のひとりごとが残っていても、新しいセリフで差し替える。検知のセリフは止めない。
        player.stop(priority: .chatter)

        if let unavailableUntil, Date() < unavailableUntil { return nil }

        do {
            let wave = try await voicevox.synthesize(text: text)
            // 通信のあいだに次のセリフが来ていたら、古い音声は鳴らさない。
            guard currentGeneration == generation else { return nil }

            guard player.play(audio: wave, priority: .chatter) else { return nil }
            // `SpeechPlayer` は長さを返さないので、鳴らせたときだけ別に測る。
            // 再生はしないので二重には鳴らない。
            return (try? AVAudioPlayer(data: wave))?.duration
        } catch {
            // エンジンが動いていないことは珍しくないので、ログに残すだけにする。
            Self.logger.debug("VOICEVOX で読み上げられなかった: \(error.localizedDescription, privacy: .public)")
            unavailableUntil = Date().addingTimeInterval(Self.retryInterval)
            return nil
        }
    }

    /// すでに用意してある音声(検知の WAV / 同封の .m4a)を鳴らす。鳴らせたら音声の長さを返す。
    ///
    /// 合成は挟まないので、ペットが吹き出しを出した瞬間にそのまま鳴らせる。
    ///
    /// - Parameter priority: 検知のセリフ(`.detection`)ならひとりごとに割り込む。
    ///   同封音声のひとりごと(`.chatter`)なら、検知のセリフが鳴っているあいだは譲る。
    func playPrepared(_ audio: Data, priority: SpeechPriority) -> TimeInterval? {
        guard player.play(audio: audio, priority: priority) else { return nil }
        // `SpeechPlayer` は長さを返さないので、鳴らせたときだけ別に測る。
        // 再生はしないので二重には鳴らない。
        return (try? AVAudioPlayer(data: audio))?.duration
    }

    /// 再生中のひとりごとを止める。合成中の結果も捨てる。検知のセリフは止めない。
    func stop() {
        generation += 1
        player.stop(priority: .chatter)
    }
}
