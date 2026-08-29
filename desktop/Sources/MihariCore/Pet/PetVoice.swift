import AVFoundation
import Foundation
import os

/// ローカルの VOICEVOX エンジンでセリフを読み上げる。
/// エンジンが動いていないときは何も鳴らさず、ユーザーには何も見せない。
@MainActor
final class PetVoice {
    /// VOICEVOX エンジンのアドレス。
    private static let baseURL = URL(string: "http://127.0.0.1:50021")!
    /// 読み上げに使う話者。冥鳴ひまり(ノーマル)。
    private static let speakerID = 14
    /// audio_query の待ち時間(秒)。
    private static let queryTimeout: TimeInterval = 2
    /// synthesis の待ち時間(秒)。
    private static let synthesisTimeout: TimeInterval = 8
    /// 失敗してから次に接続を試みるまでの間隔(秒)。
    private static let retryInterval: TimeInterval = 30

    private static let logger = Logger(
        subsystem: "com.thirdlf03.mihari",
        category: "PetVoice"
    )

    /// 再生中のプレイヤー。新しいセリフが来たら差し替える。
    private var player: AVAudioPlayer?
    /// セリフの世代。合成のあいだに次のセリフが来たかを判定するために使う。
    private var generation = 0
    /// この時刻まではエンジンへ接続しに行かない。エンジンが無いときに毎回待たされるのを防ぐ。
    private var unavailableUntil: Date?

    /// 通信に使うセッション。接続できるまで待たず、キャッシュも残さない。
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// セリフを合成して再生する。再生を始められたら音声の長さを返し、鳴らせなければ nil を返す。
    func speak(_ text: String) async -> TimeInterval? {
        generation += 1
        let currentGeneration = generation
        // 前のセリフが残っていても、新しいセリフで差し替える。
        player?.stop()
        player = nil

        if let unavailableUntil, Date() < unavailableUntil { return nil }

        do {
            let query = try await audioQuery(text: text)
            let wave = try await synthesis(query: query)
            // 通信のあいだに次のセリフが来ていたら、古い音声は鳴らさない。
            guard currentGeneration == generation else { return nil }

            let player = try AVAudioPlayer(data: wave)
            guard player.play() else { throw VoiceError.playbackFailed }
            self.player = player
            return player.duration
        } catch {
            // エンジンが動いていないことは珍しくないので、ログに残すだけにする。
            Self.logger.debug("VOICEVOX で読み上げられなかった: \(error.localizedDescription, privacy: .public)")
            unavailableUntil = Date().addingTimeInterval(Self.retryInterval)
            return nil
        }
    }

    /// 再生中の音声を止める。合成中の結果も捨てる。
    func stop() {
        generation += 1
        player?.stop()
        player = nil
    }

    /// テキストから音声合成用のクエリ(JSON)を作る。
    private func audioQuery(text: String) async throws -> Data {
        let request = try Self.makeRequest(
            path: "audio_query",
            queryItems: [
                URLQueryItem(name: "text", value: text),
                URLQueryItem(name: "speaker", value: String(Self.speakerID)),
            ],
            timeout: Self.queryTimeout
        )
        return try await send(request)
    }

    /// クエリから WAV を合成する。
    private func synthesis(query: Data) async throws -> Data {
        var request = try Self.makeRequest(
            path: "synthesis",
            queryItems: [URLQueryItem(name: "speaker", value: String(Self.speakerID))],
            timeout: Self.synthesisTimeout
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/wav", forHTTPHeaderField: "Accept")
        request.httpBody = query
        return try await send(request)
    }

    /// リクエストを送り、2xx ならボディを返す。
    private func send(_ request: URLRequest) async throws -> Data {
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VoiceError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw VoiceError.badStatus(http.statusCode) }
        return body
    }

    /// エンドポイントとクエリから POST リクエストを組み立てる。
    private static func makeRequest(
        path: String,
        queryItems: [URLQueryItem],
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else {
            throw VoiceError.invalidURL
        }
        components.queryItems = queryItems
        // URLComponents は "+" をそのまま残すが、受け取り側では空白と解釈されるのでエスケープする。
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw VoiceError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        return request
    }

    /// 読み上げに失敗した理由。ログに出すだけで、UI には出さない。
    private enum VoiceError: LocalizedError {
        /// リクエスト URL を組み立てられなかった。
        case invalidURL
        /// HTTP のレスポンスとして解釈できなかった。
        case badResponse
        /// エンジンが 2xx 以外を返した。
        case badStatus(Int)
        /// 音声を再生できなかった。
        case playbackFailed

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "リクエスト URL を組み立てられなかった"
            case .badResponse: return "HTTP のレスポンスではなかった"
            case .badStatus(let code): return "エンジンが HTTP \(code) を返した"
            case .playbackFailed: return "音声を再生できなかった"
            }
        }
    }
}
