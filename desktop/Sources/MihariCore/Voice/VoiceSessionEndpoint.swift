import Foundation

/// voice Realtime の接続先。依頼窓・部屋購読と同じ環境変数を使う。
struct VoiceSessionEndpoint: Sendable, Equatable {
    let baseURL: URL
    let token: String

    static func fromEnvironment() -> VoiceSessionEndpoint {
        VoiceSessionEndpoint(
            baseURL: JobRequestClient.defaultBaseURL,
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
