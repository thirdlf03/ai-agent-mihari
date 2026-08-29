import AVFoundation
import Foundation
import os

/// WAV を鳴らす。
///
/// 前のセリフを喋っている最中に次が来たら、前を止めて新しい方を鳴らす。
/// 溜めて順番に喋らせると、状況が変わったあとの古いセリフが遅れて流れてしまうため。
public final class SpeechPlayer: @unchecked Sendable {

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "speech")

    private var player: AVAudioPlayer?
    private let lock = NSLock()

    public init() {}

    public var isSpeaking: Bool {
        lock.lock()
        defer { lock.unlock() }
        return player?.isPlaying ?? false
    }

    /// 鳴らす。鳴らせたら `true`。
    @discardableResult
    public func play(wav: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        player?.stop()
        do {
            let next = try AVAudioPlayer(data: wav)
            next.prepareToPlay()
            guard next.play() else {
                Self.logger.error("音声の再生を開始できなかった")
                return false
            }
            player = next
            return true
        } catch {
            Self.logger.error("音声を読み込めなかった: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        player?.stop()
        player = nil
    }
}
