import Foundation

/// ローカル VOICEVOX エンジンへ `audio_query` → `synthesis` の 1 往復を送る。
///
/// ペットのひとりごと(`PetVoice`)と §5-1 の会話経路の煙テスト(`VoiceConversationSmoke`)が
/// 同じ合成口を共有する。再生や優先度の仲裁は `SpeechPlayer` 側の責務。
struct VoicevoxConfiguration: Sendable, Equatable {
    var baseURL: URL
    var speakerID: Int
    var tuning: VoicevoxQueryTuning
    var queryTimeout: TimeInterval
    var synthesisTimeout: TimeInterval

    /// 既定: 冥鳴ひまり(話者 14) / `http://127.0.0.1:50021`。
    static let standard = VoicevoxConfiguration(
        baseURL: URL(string: "http://127.0.0.1:50021")!,
        speakerID: 14,
        tuning: .standard,
        queryTimeout: 2,
        synthesisTimeout: 8
    )
}

/// VOICEVOX への HTTP 合成クライアント。
struct VoicevoxClient: Sendable {
    let configuration: VoicevoxConfiguration
    private let session: URLSession

    init(configuration: VoicevoxConfiguration = .standard, session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    /// テキストを WAV に合成する。
    func synthesize(text: String) async throws -> Data {
        let query = try await audioQuery(text: text)
        let tuned = try configuration.tuning.apply(to: query)
        return try await synthesis(query: tuned)
    }

    private func audioQuery(text: String) async throws -> Data {
        let request = try makeRequest(
            path: "audio_query",
            queryItems: [
                URLQueryItem(name: "text", value: text),
                URLQueryItem(name: "speaker", value: String(configuration.speakerID)),
            ],
            timeout: configuration.queryTimeout
        )
        return try await send(request)
    }

    private func synthesis(query: Data) async throws -> Data {
        var request = try makeRequest(
            path: "synthesis",
            queryItems: [URLQueryItem(name: "speaker", value: String(configuration.speakerID))],
            timeout: configuration.synthesisTimeout
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/wav", forHTTPHeaderField: "Accept")
        request.httpBody = query
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VoicevoxError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw VoicevoxError.badStatus(http.statusCode) }
        return body
    }

    private func makeRequest(
        path: String,
        queryItems: [URLQueryItem],
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw VoicevoxError.invalidURL
        }
        components.queryItems = queryItems
        // URLComponents は "+" をそのまま残すが、受け取り側では空白と解釈されるのでエスケープする。
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw VoicevoxError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        return request
    }
}

/// VOICEVOX への合成が失敗した理由。
enum VoicevoxError: LocalizedError, Equatable {
    case invalidURL
    case badResponse
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "リクエスト URL を組み立てられなかった"
        case .badResponse: return "HTTP のレスポンスではなかった"
        case .badStatus(let code): return "エンジンが HTTP \(code) を返した"
        }
    }
}
