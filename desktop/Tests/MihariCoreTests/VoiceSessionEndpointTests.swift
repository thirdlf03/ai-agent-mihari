import Foundation
import Testing

@testable import MihariCore

@Suite("voice 接続先 URL")
struct VoiceSessionEndpointTests {

    @Test("stream_path から ws URL を作る")
    func buildsWebSocketURL() {
        let endpoint = VoiceSessionEndpoint(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            token: "secret"
        )
        let url = endpoint.streamURL(for: "/voice/sessions/abc/stream")
        #expect(url?.scheme == "ws")
        #expect(url?.host == "127.0.0.1")
        #expect(url?.port == 8787)
        #expect(url?.path == "/voice/sessions/abc/stream")
    }

    @Test("https ベースは wss になる")
    func buildsSecureWebSocketURL() {
        let endpoint = VoiceSessionEndpoint(
            baseURL: URL(string: "https://room.example.com")!,
            token: ""
        )
        let url = endpoint.streamURL(for: "/voice/sessions/abc/stream")
        #expect(url?.scheme == "wss")
        #expect(url?.host == "room.example.com")
    }
}
