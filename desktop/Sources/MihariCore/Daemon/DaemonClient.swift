import Foundation

/// デーモンへの REST 呼び出し。
public struct DaemonClient: Sendable {

    public static let tokenHeader = "X-Mihari-Token"

    private let baseURL: URL
    private let token: String
    private let session: URLSession
    private let streamingSession: URLSession

    public init(
        baseURL: URL,
        token: String,
        session: URLSession = .shared,
        streamingSession: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.streamingSession = streamingSession ?? Self.makeStreamingSession()
    }

    /// SSE 専用のセッション。
    ///
    /// 既定のセッションはキャッシュを挟むため、終わらない応答だとバイトが手元まで降りてこない。
    /// キャッシュを外し、無音が続いても切られないようタイムアウトを長く取る。
    public static func makeStreamingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = Self.streamIdleTimeout
        configuration.timeoutIntervalForResource = Self.streamResourceTimeout
        configuration.httpShouldUsePipelining = false
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// 無音が続いても切らない秒数。デーモンは 15 秒ごとに keepalive を送る。
    static let streamIdleTimeout: TimeInterval = 300

    /// 1 本の接続を保つ上限。これを超えたら張り直す。
    static let streamResourceTimeout: TimeInterval = 60 * 60 * 24

    public func health() async throws -> DaemonHealth {
        try await get("health", authenticated: false)
    }

    public func devices(wifi: Bool = true) async throws -> DeviceListResponse {
        try await get("devices?wifi=\(wifi)")
    }

    /// 経路が通っているかを確かめるために、イベントを 1 件流させる。
    @discardableResult
    public func publishTestEvent(
        name: String,
        payload: [String: String] = [:]
    ) async throws -> PublishResponse {
        try await post("events/publish", body: PublishRequest(name: name, payload: payload))
    }

    /// セリフを作り、読み上げ用の音声まで用意させる。
    public func speak(_ request: SpeechRequest) async throws -> SpokenLine {
        try await post("voice/speak", body: request)
    }

    /// セリフだけを作る。読み上げはしない。
    public func line(for request: SpeechRequest) async throws -> SpokenLine {
        try await post("voice/line", body: request)
    }

    /// セリフ生成と読み上げが使える状態かを問い合わせる。
    public func voiceStatus() async throws -> VoiceStatus {
        try await get("voice/status")
    }

    /// SSE の接続に使うリクエスト。
    public func eventStreamRequest() throws -> URLRequest {
        var request = try makeRequest(path: "events", authenticated: true)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        // .infinity を入れると期限の計算が壊れて一切届かなくなるため、長い有限値にする。
        request.timeoutInterval = Self.streamIdleTimeout
        return request
    }

    /// SSE をつなぎ、バイト列と応答を返す。
    public func openEventStream() async throws -> (URLSession.AsyncBytes, Int) {
        let request = try eventStreamRequest()
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await streamingSession.bytes(for: request)
        } catch {
            throw DaemonError.requestFailed(status: 0, message: error.localizedDescription)
        }
        return (bytes, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func get<T: Decodable>(_ path: String, authenticated: Bool = true) async throws -> T {
        try await send(makeRequest(path: path, authenticated: authenticated))
    }

    private func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        var request = try makeRequest(path: path, authenticated: true)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func makeRequest(path: String, authenticated: Bool) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw DaemonError.requestFailed(status: 0, message: "URL を組み立てられない: \(path)")
        }
        var request = URLRequest(url: url)
        if authenticated {
            request.setValue(token, forHTTPHeaderField: Self.tokenHeader)
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DaemonError.requestFailed(status: 0, message: error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw DaemonError.requestFailed(status: status, message: Self.detail(from: data))
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DaemonError.requestFailed(status: status, message: "応答を解釈できない: \(error.localizedDescription)")
        }
    }

    private static func detail(from data: Data) -> String {
        if let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data) {
            return payload.detail
        }
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "詳細なし" : raw
    }

    private struct ErrorPayload: Decodable {
        let detail: String
    }

    private struct PublishRequest: Encodable {
        let name: String
        let payload: [String: String]
    }
}

public struct DaemonHealth: Decodable, Equatable, Sendable {
    public let status: String
    public let pid: Int
    public let subscribers: Int
}

public struct PublishResponse: Decodable, Equatable, Sendable {
    public let published: Bool
    public let name: String
    public let subscribers: Int
}

public struct DeviceSummary: Decodable, Equatable, Sendable, Identifiable {
    public let udid: String
    public let connectionType: String
    public let host: String?

    public var id: String { udid }

    enum CodingKeys: String, CodingKey {
        case udid
        case connectionType = "connection_type"
        case host
    }
}

public struct DeviceListResponse: Decodable, Equatable, Sendable {
    public let devices: [DeviceSummary]
}
