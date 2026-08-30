import Foundation
import Testing

@testable import MihariCore

@Suite("SIGTERM/SIGINT の即死防止")
struct TerminationSignalGuardTests {

    /// テスト間で await できるよう、呼ばれたことを actor で記録する。
    private actor CallRecorder {
        private(set) var callCount = 0
        func mark() { callCount += 1 }
    }

    @Test("SIGTERM を受け取っても落ちずにコールバックを呼ぶ")
    func sigtermInvokesCallbackInsteadOfDying() async throws {
        let recorder = CallRecorder()
        let guardian = TerminationSignalGuard(signals: [SIGTERM]) {
            Task { await recorder.mark() }
        }
        guardian.install()

        raise(SIGTERM)

        // DispatchSourceSignal はメインキューでの配送が非同期なので、届くまで少し待つ。
        for _ in 0..<50 {
            if await recorder.callCount > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(await recorder.callCount == 1)
    }

    @Test("SIGINT も同様にコールバックへ回す")
    func sigintInvokesCallback() async throws {
        let recorder = CallRecorder()
        let guardian = TerminationSignalGuard(signals: [SIGINT]) {
            Task { await recorder.mark() }
        }
        guardian.install()

        raise(SIGINT)

        for _ in 0..<50 {
            if await recorder.callCount > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(await recorder.callCount == 1)
    }
}
