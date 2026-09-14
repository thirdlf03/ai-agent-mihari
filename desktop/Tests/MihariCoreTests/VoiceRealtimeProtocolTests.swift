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

    @Test("user.text の逐次形式を delta / done 付きで読む")
    func parsesStreamingUserText() {
        let partial = """
            {"type":"user.text","text":"こんに","delta":"に","done":false}
            """
        let final = """
            {"type":"user.text","text":"こんにちは","done":true}
            """
        #expect(
            VoiceIncomingFrame.parse(data: Data(partial.utf8))
                == .userText(text: "こんに", delta: "に", done: false)
        )
        #expect(
            VoiceIncomingFrame.parse(data: Data(final.utf8))
                == .userText(text: "こんにちは", delta: nil, done: true)
        )
    }

    @Test("user.text の従来形式は delta / done が nil になる")
    func parsesLegacyUserText() {
        let json = """
            {"type":"user.text","text":"今日の予定を教えて"}
            """
        let frame = VoiceIncomingFrame.parse(data: Data(json.utf8))
        #expect(frame == .userText(text: "今日の予定を教えて", delta: nil, done: nil))
    }

    @Test("user.transcript_none を読む")
    func parsesUserTranscriptNone() {
        let json = """
            {"type":"user.transcript_none"}
            """
        let frame = VoiceIncomingFrame.parse(data: Data(json.utf8))
        #expect(frame == .userTranscriptNone)
    }

    @Test("input.image を base64 付きで組み立てる")
    func buildsInputImage() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let text = try VoiceOutgoingFrame.inputImage(data: png, prompt: "Describe")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(json["type"] as? String == "input.image")
        #expect(json["image_base64"] as? String == png.base64EncodedString())
        #expect(json["media_type"] as? String == "image/png")
        #expect(json["prompt"] as? String == "Describe")
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
        #expect(
            frame
                == .sessionReady(
                    sessionID: "abc",
                    model: "gpt-realtime-2.1-mini",
                    outputModalities: []
                )
        )
    }

    @Test("session.ready の output_modalities を読む")
    func parsesSessionReadyOutputModalities() {
        let json = """
            {"type":"session.ready","session_id":"abc","model":"gpt-live-1","output_modalities":["audio","text"]}
            """
        let frame = VoiceIncomingFrame.parse(data: Data(json.utf8))
        #expect(
            frame
                == .sessionReady(
                    sessionID: "abc",
                    model: "gpt-live-1",
                    outputModalities: ["audio", "text"]
                )
        )
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
        #expect(messages.first?.role == "user")
        #expect(messages.first?.text == "こんにちは")
        #expect(messages.first?.kind == "text")
        #expect(messages.dropFirst(2).first?.kind == "image_prompt")
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

    @Test("assistant.tool_activity を name / call_id / status 付きで読む")
    func parsesAssistantToolActivity() {
        let json = """
            {"type":"assistant.tool_activity","name":"submit_job","call_id":"c1","status":"done"}
            """
        let frame = VoiceIncomingFrame.parse(data: Data(json.utf8))
        #expect(
            frame
                == .assistantToolActivity(
                    name: "submit_job",
                    callID: "c1",
                    status: "done"
                )
        )
    }

    @Test("assistant.tool_activity の status は running / failed も読める")
    func parsesAssistantToolActivityStatuses() {
        for status in ["running", "failed"] {
            let json = """
                {"type":"assistant.tool_activity","name":"get_job_status","call_id":"c2","status":"\(status)"}
                """
            let frame = VoiceIncomingFrame.parse(data: Data(json.utf8))
            #expect(
                frame
                    == .assistantToolActivity(
                        name: "get_job_status",
                        callID: "c2",
                        status: status
                    )
            )
        }
    }

    @Test("assistant.tool_call を name / call_id / arguments 付きで読む")
    func parsesAssistantToolCall() {
        let json = """
            {"type":"assistant.tool_call","name":"steer_job","call_id":"c9","arguments":"{\\"instruction\\":\\"急いで\\"}"}
            """
        let frame = VoiceIncomingFrame.parse(data: Data(json.utf8))
        #expect(
            frame
                == .assistantToolCall(
                    name: "steer_job",
                    callID: "c9",
                    arguments: #"{"instruction":"急いで"}"#
                )
        )
    }

    @Test("error と session.closed を読む")
    func parsesErrorAndSessionClosed() {
        let errorJSON = """
            {"type":"error","code":"upstream_timeout","message":"部屋がタイムアウトした"}
            """
        let closedJSON = """
            {"type":"session.closed","reason":"idle"}
            """
        #expect(
            VoiceIncomingFrame.parse(data: Data(errorJSON.utf8))
                == .error(code: "upstream_timeout", message: "部屋がタイムアウトした")
        )
        #expect(
            VoiceIncomingFrame.parse(data: Data(closedJSON.utf8))
                == .sessionClosed(reason: "idle")
        )
    }

    @Test("assistant.audio を base64 と done で読む")
    func parsesAssistantAudio() {
        let pcm = Data([0x01, 0x00, 0xFF, 0x7F])
        let json = """
            {"type":"assistant.audio","audio_base64":"\(pcm.base64EncodedString())","done":false}
            """
        let frame = VoiceIncomingFrame.parse(data: Data(json.utf8))
        #expect(frame == .assistantAudio(pcm16: pcm, done: false))
    }

    @Test("assistant.audio の done 通知だけのフレームは空音声になる")
    func parsesAssistantAudioDoneOnly() {
        let json = """
            {"type":"assistant.audio","audio_base64":"","done":true}
            """
        let frame = VoiceIncomingFrame.parse(data: Data(json.utf8))
        #expect(frame == .assistantAudio(pcm16: Data(), done: true))
    }

    @Test("assistant.text は text フィールドも delta として扱う")
    func parsesAssistantTextFromTextField() {
        let json = """
            {"type":"assistant.text","text":"全文","done":true}
            """
        let frame = VoiceIncomingFrame.parse(data: Data(json.utf8))
        #expect(frame == .assistantText(delta: "", text: "全文", done: true))
    }

    @Test("history.sync の ts が NSNumber でも tool_name を読む")
    func parsesHistorySyncWithNSNumberTimestamp() {
        let raw: [String: Any] = [
            "role": "assistant",
            "text": "",
            "ts": NSNumber(value: 42.5),
            "kind": "tool_call",
            "tool_name": "capture_screen",
            "tool_arguments": #"{"prompt":"見て"}"#,
        ]
        let entry = VoiceHistorySyncEntry.parse(from: raw)
        #expect(entry?.timestamp == Date(timeIntervalSince1970: 42.5))
        #expect(entry?.toolName == "capture_screen")
        #expect(entry?.toolArguments == #"{"prompt":"見て"}"#)
    }

    @Test("空テキストの user / assistant は履歴行にしない")
    func skipsEmptyHistoryText() {
        let user = VoiceHistorySyncEntry(
            role: "user",
            text: "  ",
            timestamp: Date(),
            kind: "text",
            toolName: "",
            toolArguments: ""
        )
        let assistant = VoiceHistorySyncEntry(
            role: "assistant",
            text: "",
            timestamp: Date(),
            kind: "text",
            toolName: "",
            toolArguments: ""
        )
        #expect(user.asConversationMessage() == nil)
        #expect(assistant.asConversationMessage() == nil)
    }

    @Test("input.image は create_response を省略可能")
    func buildsInputImageWithoutAutoResponse() throws {
        let png = Data([0x01])
        let text = try VoiceOutgoingFrame.inputImage(data: png, prompt: "見て", createResponse: false)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(json["create_response"] as? Bool == false)
    }

    @Test("input.audio は commit なしのストリーミングを組み立てる")
    func buildsStreamingInputAudio() throws {
        let pcm = Data([0x0A, 0x0B])
        let text = try VoiceOutgoingFrame.inputAudio(pcm16: pcm, commit: false, createResponse: false)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(json["commit"] as? Bool == false)
        #expect(json["create_response"] as? Bool == false)
    }

    @Test("created セッションは isReconnectable")
    func createdSessionIsReconnectable() throws {
        let json = """
            {"session_id":"s1","model":"gpt-realtime-2.1-mini","status":"created","error":null}
            """
        let status = try JSONDecoder().decode(VoiceSessionStatusResponse.self, from: Data(json.utf8))
        #expect(status.isReconnectable)
    }
}
