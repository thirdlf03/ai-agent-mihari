import Foundation

/// voice Realtime の WebSocket 1 本。テストではスタブに差し替える。
protocol VoiceStreamSocket: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String?
    func close() async
}

/// voice ストリーム接続を作る工場。
protocol VoiceStreamSocketFactory: Sendable {
    func makeSocket(url: URL, token: String) async throws -> any VoiceStreamSocket
}

/// `URLSessionWebSocketTask` を使う実装。
struct WebSocketVoiceStreamSocketFactory: VoiceStreamSocketFactory {
    func makeSocket(url: URL, token: String) async throws -> any VoiceStreamSocket {
        var request = URLRequest(url: url)
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: DaemonClient.tokenHeader)
        }
        request.timeoutInterval = 3600
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        return WebSocketVoiceStreamSocket(task: task, session: session)
    }
}

private struct WebSocketVoiceStreamSocket: VoiceStreamSocket {
    private let task: URLSessionWebSocketTask
    private let session: URLSession

    init(task: URLSessionWebSocketTask, session: URLSession) {
        self.task = task
        self.session = session
    }

    func send(_ text: String) async throws {
        task.resume()
        try await task.send(.string(text))
    }

    func receive() async throws -> String? {
        task.resume()
        switch try await task.receive() {
        case .string(let text):
            return text
        case .data(let data):
            return String(data: data, encoding: .utf8)
        @unknown default:
            return nil
        }
    }

    func close() async {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}
