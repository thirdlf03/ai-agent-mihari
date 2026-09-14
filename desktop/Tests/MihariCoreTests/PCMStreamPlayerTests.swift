import AVFoundation
import Foundation
import Testing

@testable import MihariCore

@Suite("PCM ストリーム再生")
struct PCMStreamPlayerTests {

    private func makeFormat() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: PCMStreamPlayer.sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    @Test("PCM16 little-endian を float32 に変換する")
    func convertsPCM16ToFloat() throws {
        // 0x0000 → 0、0x7FFF → ≈+1、0x8000 → -1（リトルエンディアンで並べる）。
        let pcm = Data([0x00, 0x00, 0xFF, 0x7F, 0x00, 0x80])
        let buffer = try #require(PCMStreamPlayer.makeFloatBuffer(pcm16: pcm, format: makeFormat()))

        #expect(buffer.frameLength == 3)
        let channel = try #require(buffer.floatChannelData?[0])
        #expect(abs(channel[0] - 0) < 0.0001)
        #expect(abs(channel[1] - (32_767.0 / 32_768.0)) < 0.0001)
        #expect(abs(channel[2] - (-1.0)) < 0.0001)
    }

    @Test("奇数バイトの端数は捨てる")
    func dropsTrailingOddByte() throws {
        let pcm = Data([0x01, 0x00, 0xFF])
        let buffer = try #require(PCMStreamPlayer.makeFloatBuffer(pcm16: pcm, format: makeFormat()))
        #expect(buffer.frameLength == 1)
    }

    @Test("空のチャンクはバッファを作らない")
    func emptyChunkMakesNoBuffer() {
        #expect(PCMStreamPlayer.makeFloatBuffer(pcm16: Data(), format: makeFormat()) == nil)
    }

    /// `@Sendable` な onDrained から書き換えるためのフラグ。
    private final class DrainFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _fired = false

        var fired: Bool { lock.withLock { _fired } }

        func reset() { lock.withLock { _fired = false } }

        func fire() { lock.withLock { _fired = true } }
    }

    @Test("stop 後は鳴らし切り通知を呼ばない")
    func stopDoesNotDrain() {
        let player = PCMStreamPlayer()
        let flag = DrainFlag()
        player.onDrained = { flag.fire() }

        player.finish()
        #expect(flag.fired)
        flag.reset()

        // finish 済み発話が無い状態で stop しても通知は来ない。
        player.stop()
        #expect(!flag.fired)
    }

    @Test("溜まった分が無い finish は即座に drain する")
    func finishWithoutBuffersDrainsImmediately() {
        let player = PCMStreamPlayer()
        let flag = DrainFlag()
        player.onDrained = { flag.fire() }

        player.finish()

        #expect(flag.fired)
    }
}
