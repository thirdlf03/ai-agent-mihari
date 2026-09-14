import Foundation

/// voice Realtime の接続先。既定は依頼窓・部屋購読と同じ部屋 URL。
/// `MIHARI_VOICE_GATEWAY_URL` を立てると音声会話だけローカル gateway
/// （`mihari_room.voice_gateway`）へ向き、仕事依頼は従来どおり部屋へ行く。
struct VoiceSessionEndpoint: Sendable, Equatable {
    /// voice セッションだけを向かせたい先を決める環境変数。
    static let gatewayURLEnvironmentKey = "MIHARI_VOICE_GATEWAY_URL"

    let baseURL: URL
    let token: String

    static func fromEnvironment() -> VoiceSessionEndpoint {
        let raw = ProcessInfo.processInfo.environment[gatewayURLEnvironmentKey] ?? ""
        return VoiceSessionEndpoint(
            baseURL: URL(string: raw) ?? JobRequestClient.defaultBaseURL,
            token: JobRequestClient.defaultToken()
        )
    }

    /// `stream_path`（`/voice/sessions/{id}/stream`）から WebSocket URL を作る。
    func streamURL(for streamPath: String) -> URL? {
        let trimmed = streamPath.hasPrefix("/") ? String(streamPath.dropFirst()) : streamPath
        guard
            var components = URLComponents(
                url: baseURL.appendingPathComponent(trimmed),
                resolvingAgainstBaseURL: false
            )
        else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        default: components.scheme = "ws"
        }
        return components.url
    }
}
