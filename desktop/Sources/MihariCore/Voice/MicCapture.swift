import AVFoundation
import Foundation

/// マイクから PCM16 モノラルを取り出す口。音声ファイルは保存しない。
protocol MicCapturing: AnyObject {
    /// PCM16 チャンクと RMS レベル(0…1)。
    var onChunk: (@Sendable (Data, Float) -> Void)? { get set }
    func start() throws
    func stop()
    var isRunning: Bool { get }
}

/// OpenAI Realtime 向けの PCM16 モノラル 24 kHz。
enum MicCaptureFormat {
    static let sampleRate: Double = 24_000
    static let bytesPerSample = 2
}

/// `AVAudioEngine` でマイクを取り、24 kHz PCM16 に変換する。
final class AVAudioMicCapture: MicCapturing {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var _isRunning = false
    private let lock = NSLock()

    var onChunk: (@Sendable (Data, Float) -> Void)?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isRunning
    }

    func start() throws {
        lock.lock()
        if _isRunning {
            lock.unlock()
            return
        }
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: MicCaptureFormat.sampleRate,
                channels: 1,
                interleaved: true
            )
        else {
            throw MicCaptureError.formatUnavailable
        }
        targetFormat = target
        converter = AVAudioConverter(from: inputFormat, to: target)

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        engine.prepare()
        try engine.start()

        lock.lock()
        _isRunning = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        guard _isRunning else {
            lock.unlock()
            return
        }
        _isRunning = false
        lock.unlock()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        targetFormat = nil
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        guard
            let converter,
            let targetFormat,
            let handler = onChunk
        else {
            return
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard
            let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity)
        else {
            return
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
        guard error == nil, converted.frameLength > 0 else { return }

        guard let channel = converted.int16ChannelData?[0] else { return }
        let count = Int(converted.frameLength)
        var sum: Float = 0
        for index in 0..<count {
            let sample = Float(channel[index]) / Float(Int16.max)
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(max(count, 1)))

        var data = Data(count: count * MicCaptureFormat.bytesPerSample)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for index in 0..<count {
                base[index] = channel[index]
            }
        }
        handler(data, rms)
    }
}

enum MicCaptureError: Error, Equatable, Sendable {
    case formatUnavailable
    case permissionDenied
}

extension MicCaptureError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .formatUnavailable:
            return "マイクの形式を取得できなかった"
        case .permissionDenied:
            return "マイクの使用が許可されていない"
        }
    }
}
