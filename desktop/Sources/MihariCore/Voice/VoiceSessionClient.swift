import Foundation

/// room の voice Realtime HTTP API（`POST/GET /voice/sessions`）。
struct VoiceSessionClient: Sendable {
    private let endpoint: VoiceSessionEndpoint
    private let session: URLSession

    init(endpoint: VoiceSessionEndpoint = .fromEnvironment(), session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    /// 環境変数から組み立てる。
    static func makeFromEnvironment(session: URLSession = .shared) -> VoiceSessionClient {
        VoiceSessionClient(endpoint: .fromEnvironment(), session: session)
    }

    /// セッションを作成する。
    func createSession() async throws -> VoiceSessionCreateResponse {
        try await send(method: "POST", path: "voice/sessions", body: nil)
    }

    /// セッション状態を取得する。
    func sessionStatus(sessionID: String) async throws -> VoiceSessionStatusResponse {
        try await send(method: "GET", path: "voice/sessions/\(sessionID)", body: nil)
    }

    private func send<Response: Decodable>(
        method: String,
        path: String,
        body: Data?
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: endpoint.baseURL) else {
            throw VoiceSessionError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(endpoint.token, forHTTPHeaderField: DaemonClient.tokenHeader)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw VoiceSessionError.requestFailed(status: 0, message: error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw VoiceSessionError.requestFailed(status: status, message: Self.detail(from: data))
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw VoiceSessionError.requestFailed(
                status: status,
                message: "応答を解釈できない: \(error.localizedDescription)"
            )
        }
    }

    private static func detail(from data: Data) -> String {
        if
            let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data)
        {
            return payload.detail
        }
        let raw =
            String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        return raw.isEmpty ? "詳細なし" : raw
    }

    private struct ErrorPayload: Decodable {
        let detail: String
    }
}

/// HTTP でセッションを作り、WebSocket を張る。
struct VoiceStreamConnector: Sendable {
    let client: VoiceSessionClient
    let socketFactory: any VoiceStreamSocketFactory
    let endpoint: VoiceSessionEndpoint

    init(
        client: VoiceSessionClient = .makeFromEnvironment(),
        socketFactory: any VoiceStreamSocketFactory = WebSocketVoiceStreamSocketFactory(),
        endpoint: VoiceSessionEndpoint = .fromEnvironment()
    ) {
        self.client = client
        self.socketFactory = socketFactory
        self.endpoint = endpoint
    }

    /// 新規セッションを作って WebSocket を開く。
    func connectNew() async throws -> VoiceStreamConnection {
        let created = try await client.createSession()
        let socket = try await openStream(sessionID: created.sessionID, streamPath: created.streamPath)
        return VoiceStreamConnection(
            sessionID: created.sessionID,
            model: created.model,
            streamPath: created.streamPath,
            socket: socket
        )
    }

    /// セッションが `created` / `streaming` なら張り直す。`closed` 等なら `nil`。
    func tryReconnect(sessionID: String, streamPath: String) async throws -> VoiceStreamConnection? {
        let status = try await client.sessionStatus(sessionID: sessionID)
        guard status.isReconnectable else { return nil }
        return try await reconnect(sessionID: sessionID, streamPath: streamPath)
    }

    /// 既存セッションへ WebSocket を張り直す。
    func reconnect(sessionID: String, streamPath: String) async throws -> VoiceStreamConnection {
        let status = try await client.sessionStatus(sessionID: sessionID)
        guard status.isReconnectable else {
            throw VoiceSessionError.requestFailed(
                status: 0,
                message: "セッションは \(status.status) のため再接続できない"
            )
        }
        let socket = try await openStream(sessionID: sessionID, streamPath: streamPath)
        return VoiceStreamConnection(
            sessionID: sessionID,
            model: status.model,
            streamPath: streamPath,
            socket: socket
        )
    }

    private func openStream(sessionID: String, streamPath: String) async throws -> any VoiceStreamSocket {
        guard let url = endpoint.streamURL(for: streamPath) else {
            throw VoiceSessionError.invalidURL
        }
        return try await socketFactory.makeSocket(url: url, token: endpoint.token)
    }
}

/// 確立した voice ストリーム。
struct VoiceStreamConnection: Sendable {
    let sessionID: String
    let model: String
    let streamPath: String
    let socket: any VoiceStreamSocket
}
