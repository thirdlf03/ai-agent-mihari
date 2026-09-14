import AVFoundation
import Foundation
import os

/// `assistant.audio` の PCM16 24 kHz モノラルを逐次再生する口。テストではスタブに差し替える。
protocol PCMStreamPlaying: AnyObject {
    /// `finish()` 済みの発話を最後まで鳴らし切ったときに呼ばれる。
    /// 呼ばれるスレッドは再生スレッド任せなので、`@MainActor` の状態を触るなら載せ替えること。
    var onDrained: (@Sendable () -> Void)? { get set }
    /// 出力エンジンを起動する。呼ばなくても `enqueue` が必要時に起こすが、
    /// セッション開始時に暖めておくと最初のチャンクの遅れが減る。冪等。
    func start()
    /// 届いた PCM16 チャンクを再生キューに積む。
    func enqueue(pcm16: Data)
    /// 1 発話の終端（`done`）。溜まった分を鳴らし切ったら `onDrained` を呼ぶ。
    func finish()
    /// 再生中断とエンジン停止（割り込み・会話終了・切断時）。積み残しは捨てる。
    func stop()
}

/// room が VC 済みで返す音声（`assistant.audio`）を `AVAudioPlayerNode` で逐次再生する。
///
/// 届いた順にバッファをスケジュールし、ノードが再生し終わると次へ進む。
/// `finish()` は「この発話はここまで」の印で、積まれた分を鳴らし切った時点で
/// `onDrained` を 1 度だけ呼ぶ。`stop()` で止めた分については呼ばない。
/// `SpeechPlayer`（VOICEVOX 経路）とは別系統で、混ざらないよう使い分けは
/// `VoiceConversationController` が行う。
final class PCMStreamPlayer: PCMStreamPlaying, @unchecked Sendable {

    /// `input.audio` と同じ 24 kHz。room は VC 出力をこのレートで返す。
    static let sampleRate: Double = 24_000

    private static let logger = Logger(subsystem: "com.thirdlf03.mihari", category: "pcmStream")

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    /// 24 kHz float32 mono。取れない場合は nil で、enqueue は何もしない。
    private let format: AVAudioFormat?
    private let lock = NSLock()

    /// `start()` でエンジンが動いているか。`stop()` / 起動失敗で false に戻る。
    private var started = false
    /// まだ再生し終わっていないスケジュール済みバッファ数。
    private var pendingBuffers = 0
    /// 今の発話の終端（`finish`）を受け取ったか。`onDrained` を呼んだら次の発話のため戻す。
    private var finishRequested = false
    private var drainedHandler: (@Sendable () -> Void)?

    init() {
        // 固定形式（24 kHz float32 mono）なので取れないはずだが、取れなければ再生を諦める。
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        )
        if let format {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        } else {
            Self.logger.error("再生形式（24 kHz float32 mono）を作れなかった")
        }
    }

    var onDrained: (@Sendable () -> Void)? {
        get {
            lock.withLock { drainedHandler }
        }
        set {
            lock.withLock { drainedHandler = newValue }
        }
    }

    func start() {
        lock.lock()
        ensureStartedLocked()
        lock.unlock()
    }

    func enqueue(pcm16: Data) {
        guard
            let format,
            let buffer = Self.makeFloatBuffer(pcm16: pcm16, format: format)
        else {
            return
        }
        lock.lock()
        // 割り込みで stop されたあとも次のチャンクで再開できるよう、ここでも起こす。
        ensureStartedLocked()
        guard started else {
            lock.unlock()
            return
        }
        pendingBuffers += 1
        lock.unlock()

        // 完了ハンドラは AVAudioEngine の再生スレッドで呼ばれる。
        node.scheduleBuffer(buffer) { [weak self] in
            self?.bufferDidComplete()
        }
    }

    func finish() {
        lock.lock()
        finishRequested = true
        // 溜まった分が無ければ（done 通知だけのフレームなど）その場で drain 扱いにする。
        let drained = pendingBuffers == 0
        if drained {
            finishRequested = false
        }
        let handler = drained ? drainedHandler : nil
        lock.unlock()
        handler?()
    }

    func stop() {
        lock.lock()
        started = false
        pendingBuffers = 0
        finishRequested = false
        lock.unlock()
        node.stop()
        engine.stop()
    }

    /// PCM16 little-endian を float32 バッファに変換する。奇数バイトの端数は捨てる。
    static func makeFloatBuffer(pcm16: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = pcm16.count / 2
        guard
            frameCount > 0,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ),
            let channel = buffer.floatChannelData?[0]
        else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        pcm16.withUnsafeBytes { raw in
            for index in 0..<frameCount {
                // 2 バイトを LE で読み、Int16.max ではなく 32768 で割ると Int16.min がちょうど -1.0 になる。
                let low = Int16(raw[index * 2])
                let high = Int16(raw[index * 2 + 1]) << 8
                channel[index] = Float(high | low) / 32_768.0
            }
        }
        return buffer
    }

    /// ロックを取った状態で呼ぶこと。エンジンとノードが動いていなければ起こす。
    private func ensureStartedLocked() {
        // ノードが未接続（format が作れなかった）ときは起動しない。
        guard format != nil else { return }
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                Self.logger.error(
                    "出力エンジンを起動できなかった: \(error.localizedDescription, privacy: .public)"
                )
                started = false
                return
            }
        }
        if !node.isPlaying {
            node.play()
        }
        started = true
    }

    private func bufferDidComplete() {
        lock.lock()
        pendingBuffers = max(0, pendingBuffers - 1)
        let drained = finishRequested && pendingBuffers == 0
        if drained {
            finishRequested = false
        }
        let handler = drained ? drainedHandler : nil
        lock.unlock()
        // ロックの外で呼ぶ。受け取った側がそのまま次を鳴らしても詰まらないようにする。
        handler?()
    }
}
