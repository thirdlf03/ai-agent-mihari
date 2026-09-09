import Foundation
import Testing

@testable import MihariCore

@Suite("voice Realtime 契約フレーム")
struct VoiceRealtimeProtocolTests {

    @Test("assistant.text を delta + done で組み立てる")
    func parsesAssistantText() {
        let json = """
        {"type":"assistant.text","delta":"こん","done":false}
        """
        let frame = VoiceIncomingFrame.parse(data: Data(json.utf8))
        #expect(frame == .assistantText(delta: "こん", text: "", done: false))
    }

    @Test("input.audio を base64 付きで組み立てる")
    func buildsInputAudio() throws {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let text = try VoiceOutgoingFrame.inputAudio(pcm16: pcm, commit: true, createResponse: true)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(json["type"] as? String == "input.audio")
        #expect(json["commit"] as? Bool == true)
        #expect(json["create_response"] as? Bool == true)
        #expect(json["audio_base64"] as? String == pcm.base64EncodedString())
    }

    @Test("session.ready を読む")
    func parsesSessionReady() {
        let json = """
        {"type":"session.ready","session_id":"abc","model":"gpt-realtime-2.1-mini"}
        """
        let frame = VoiceIncomingFrame.parse(data: Data(json.utf8))
        #expect(frame == .sessionReady(sessionID: "abc", model: "gpt-realtime-2.1-mini"))
    }

    @Test("history.sync を messages 付きで読む")
    func parsesHistorySync() {
        let json = """
        {"type":"history.sync","messages":[\
        {"role":"user","text":"こんにちは","ts":1.0,"kind":"text"},\
        {"role":"assistant","text":"やあ","ts":2.0,"kind":"text"},\
        {"role":"user","text":"画面見て","ts":3.0,"kind":"image_prompt"}\
        ]}
        """
        let frame = VoiceIncomingFrame.parse(data: Data(json.utf8))
        guard case .historySync(let messages) = frame else {
            Issue.record("history.sync として解釈されるべき")
            return
        }
        #expect(messages.count == 3)
        #expect(messages[0].role == "user")
        #expect(messages[0].text == "こんにちは")
        #expect(messages[0].kind == "text")
        #expect(messages[2].kind == "image_prompt")
    }

    @Test("history.sync の tool_call は system メッセージになる")
    func mapsToolCallEntry() {
        let entry = VoiceHistorySyncEntry(
            role: "assistant",
            text: "",
            timestamp: Date(timeIntervalSince1970: 0),
            kind: "tool_call",
            toolName: "echo_phrase",
            toolArguments: #"{"phrase":"hi"}"#
        )
        let message = entry.asConversationMessage()
        #expect(message?.role == .system)
        #expect(message?.text == "ツール呼び出し: echo_phrase")
    }
}
