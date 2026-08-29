import AVFoundation
import Foundation
import os

/// WAV を鳴らす。**アプリで唯一の音の出口。**
///
/// 検知のセリフとペットのひとりごとが同じこれを共有し、どちらを鳴らすかは
/// `SpeechPlaybackArbiter` が決める。声ごとに `AVAudioPlayer` を持つと二重に鳴るため、
/// プレイヤーは常に 1 つだけにする。
///
/// 前のセリフを喋っている最中に次が来たら、前を止めて新しい方を鳴らす。
/// 溜めて順番に喋らせると、状況が変わったあとの古いセリフが遅れて流れてしまうため。
public final class SpeechPlayer: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "speech")

    private var player: AVAudioPlayer?
    /// いま鳴らしているものの優先度。鳴らしていなければ `nil`。
    private var activePriority: SpeechPriority?
    private var finishedHandler: (@Sendable (SpeechPriority) -> Void)?
    private let lock = NSLock()

    public override init() {
        super.init()
    }

    /// 再生が**自然に終わった**ときに、終わったものの優先度を渡して呼ばれる。
    ///
    /// `stop()` / `stop(priority:)` で止めたときと、次のセリフに差し替えられたときは呼ばれない。
    /// 「もう喋っていない」を知りたい側は、自分で止めたことは知っているため。
    /// 呼ばれるスレッドは `AVAudioPlayer` 任せなので、`@MainActor` の状態を触るなら載せ替えること。
    public var onPlaybackFinished: (@Sendable (SpeechPriority) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return finishedHandler
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            finishedHandler = newValue
        }
    }

    public var isSpeaking: Bool {
        lock.lock()
        defer { lock.unlock() }
        return player?.isPlaying ?? false
    }

    /// いま鳴らしているものの優先度。鳴らしていなければ `nil`。
    public var currentPriority: SpeechPriority? {
        lock.lock()
        defer { lock.unlock() }
        return playingPriority()
    }

    /// 検知のセリフとして鳴らす。鳴らせたら `true`。
    @discardableResult
    public func play(wav: Data) -> Bool {
        play(wav: wav, priority: .detection)
    }

    /// 鳴らす。鳴らせたら `true`。
    ///
    /// `SpeechPlaybackArbiter` が `.drop` と判定したら、何もせずに `false` を返す
    /// (鳴っているものは止めない)。`.play` なら鳴っているものを止めて差し替える。
    @discardableResult
    public func play(wav: Data, priority: SpeechPriority) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard SpeechPlaybackArbiter.decide(current: playingPriority(), requested: priority) == .play else {
            return false
        }

        clearPlayer()
        do {
            let next = try AVAudioPlayer(data: wav)
            next.delegate = self
            next.prepareToPlay()
            guard next.play() else {
                Self.logger.error("音声の再生を開始できなかった")
                return false
            }
            player = next
            activePriority = priority
            return true
        } catch {
            Self.logger.error("音声を読み込めなかった: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 優先度によらず止める。
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        clearPlayer()
    }

    /// 鳴っているものが `priority` **以下**のときだけ止める。
    ///
    /// ひとりごとの都合(`stop(priority: .chatter)`)で検知のセリフを黙らせないため。
    public func stop(priority: SpeechPriority) {
        lock.lock()
        defer { lock.unlock() }
        guard let active = activePriority, active <= priority else { return }
        clearPlayer()
    }

    public func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        lock.lock()
        guard finished === player else {
            // すでに差し替えられた古いプレイヤー。いまの再生の話ではないので触らない。
            lock.unlock()
            return
        }
        let priority = activePriority
        let handler = finishedHandler
        player = nil
        activePriority = nil
        lock.unlock()

        if !flag {
            Self.logger.error("音声の再生が最後まで終わらなかった")
        }
        guard let priority else { return }
        // ロックの外で呼ぶ。受け取った側がそのまま次を鳴らしても詰まらないようにする。
        handler?(priority)
    }

    /// ロックを取った状態で呼ぶこと。
    private func playingPriority() -> SpeechPriority? {
        guard player?.isPlaying == true else { return nil }
        return activePriority
    }

    /// ロックを取った状態で呼ぶこと。
    private func clearPlayer() {
        player?.stop()
        player = nil
        activePriority = nil
    }
}
