import Foundation

/// WebSocket 1 本の差し替え可能な口。
///
/// 実体は `URLSessionWebSocketTask`。テストでは固定の応答を返すスタブに差し替える。
/// `receive()` は 1 フレーム(JSON テキスト)ごとに 1 回呼ばれ、切断・エラーで `nil` / throw する。
public protocol MacControlSocket: Sendable {
    /// フレームを送る。
    func send(_ text: String) async throws
    /// 次のフレームを待つ。閉じたら `nil`。
    func receive() async throws -> String?
    /// 閉じる。`receive()` を待たせたままでも確実に抜けられること。
    func close() async
}

/// 接続を作る工場。`MacControlCenter` はここから 1 本ずつ張る。
public protocol MacControlSocketFactory: Sendable {
    func makeSocket(endpoint: MacControlEndpoint) async throws -> any MacControlSocket
}

/// `URLSessionWebSocketTask` を使う実装。
public struct WebSocketMacControlSocketFactory: MacControlSocketFactory {

    public init() {}

    public func makeSocket(endpoint: MacControlEndpoint) async throws -> any MacControlSocket {
        guard let url = endpoint.socketURL else {
            throw MacControlSocketError.invalidURL
        }
        var request = URLRequest(url: url)
        // トークンはヘッダにのみ載せる。URL / ログには出さない。
        if !endpoint.token.isEmpty {
            request.setValue(endpoint.token, forHTTPHeaderField: DaemonClient.tokenHeader)
        }
        request.timeoutInterval = 3600
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        return WebSocketMacControlSocket(
            task: task,
            session: session
        )
    }
}

public enum MacControlSocketError: Error, Sendable {
    case invalidURL
}

private struct WebSocketMacControlSocket: MacControlSocket {

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
